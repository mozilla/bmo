#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Project: project.search lookups, project.edit create/update
# transactions and the lazy members list.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Storable qw(dclone);
use Test::More;
use Test2::Tools::Exception qw(dies);

use Bugzilla::Extension::PhabBugz::Project;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

use constant Project => 'Bugzilla::Extension::PhabBugz::Project';

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

my $alice      = $env->bmo_user('alice');
my $alice_phab = $env->link_user($alice);
my $unlinked   = $conduit->add_user(user_obj(username => 'phabtest-unlinked'));

my $name  = $env->unique('proj');
my $exact = $conduit->add_project(project_obj(
  name        => $name,
  description => 'The exact match',
  view_policy => 'PHID-PROJ-viewers',
  edit_policy => 'PHID-PROJ-editors',
  join_policy => 'PHID-PROJ-joiners',
  members     => [$alice_phab->{phid}, $unlinked->{phid}],
));

# Created after the exact match, so Conduit returns it first.
my $longer = $conduit->add_project(project_obj(name => "$name-and-more"));

# new_from_query by name picks the exact match out of the tokenized results
{
  $conduit->reset_calls;
  my $project = Project->new_from_query({name => $name});
  is($project->phid, $exact->{phid}, 'exact name match wins over a longer name');
  is_deeply(
    [$conduit->calls('project.search')],
    [{
      queryKey    => 'all',
      attachments => {members => 1},
      constraints => {name    => $name}
    }],
    'project.search params'
  );

  ok(!Project->new_from_query({name => substr($name, 0, -1)}),
    'a prefix of a project name is not a match');
  ok(!Project->new_from_query({name => $env->unique('missing')}),
    'unknown name finds nothing');

  is(Project->new_from_query({phids => [$longer->{phid}]})->phid,
    $longer->{phid}, 'lookup by phids returns the first result');
}

# Constructor maps Conduit fields
{
  my $project = Project->new(dclone($exact));
  is($project->id,              $exact->{id},        'id');
  is($project->name,            $name,               'name');
  is($project->description,     'The exact match',   'description');
  is($project->view_policy,     'PHID-PROJ-viewers', 'view policy');
  is($project->edit_policy,     'PHID-PROJ-editors', 'edit policy');
  is($project->join_policy,     'PHID-PROJ-joiners', 'join policy');
  is($project->creation_ts,     1500403964,          'creation_ts');
  is($project->modification_ts, 1505248862,          'modification_ts');
  is_deeply($project->members_raw,
    [{phid => $alice_phab->{phid}}, {phid => $unlinked->{phid}}],
    'members_raw');
}

# members is loaded lazily with user.search
{
  my $project = Project->new(dclone($exact));
  $conduit->reset_calls;
  my $members = $project->members;
  is_deeply([sort map { $_->phid } @$members],
    [sort $alice_phab->{phid}, $unlinked->{phid}], 'members');
  is($conduit->call_count('user.search'), 1, 'one user.search for members');
  $project->members;
  is($conduit->call_count('user.search'), 1, 'members is cached');

  my $empty = Project->new(project_obj(members => []));
  $conduit->reset_calls;
  is_deeply($empty->members, [], 'project without members');
  is($conduit->call_count, 0, 'no user.search for an empty project');
}

# create
{
  $conduit->reset_calls;
  my $new_name = $env->unique('created');
  my $project  = Project->create({
    name        => "  $new_name  ",
    description => 'Created by the test',
    view_policy => 'PHID-PROJ-view',
    edit_policy => 'PHID-PROJ-edit',
    join_policy => 'PHID-PROJ-join',
  });

  my ($edit) = $conduit->calls('project.edit');
  ok(!exists $edit->{objectIdentifier}, 'create sends no objectIdentifier');
  is_deeply(
    $edit->{transactions},
    [
      {type => 'name',        value => $new_name},
      {type => 'description', value => 'Created by the test'},
      {type => 'edit',        value => 'PHID-PROJ-edit'},
      {type => 'join',        value => 'PHID-PROJ-join'},
      {type => 'view',        value => 'PHID-PROJ-view'},
      {type => 'icon',        value => 'group'},
      {type => 'color',       value => 'red'},
    ],
    'create transactions (name trimmed)'
  );

  my $created = $conduit->find_project(name => $new_name);
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('project.search')],
    [{phids => [$created->{phid}]}],
    'create reloads the project by the PHID project.edit returned'
  );
  is($project->name, $new_name, 'returned project has the name');
  is($project->join_policy, 'PHID-PROJ-join',
    'returned project has the policies');

  ok(
    dies { Project->create({name => 'incomplete'}) },
    'create requires all policies and a description'
  );

  $conduit->queue(
    'project.edit' => conduit_error('ERR-CONDUIT-CORE', 'Name already used'));
  throws_error(
    sub {
      Project->create({
        name        => $new_name,
        description => 'dupe',
        view_policy => 'x',
        edit_policy => 'x',
        join_policy => 'x',
      });
    },
    'bugzilla.code.phabricator_api_error',
    'project.edit error during create propagates'
  );
}

# update with add/remove members and policies
{
  my $project  = Project->new(dclone($exact));
  my $bob_phab = $env->link_user($env->bmo_user('bob'));
  my $bob_user = Bugzilla::Extension::PhabBugz::User->new(dclone($bob_phab));

  $project->set_name('  renamed  ');
  $project->set_description('  new description ');
  $project->add_member($bob_user);
  $project->add_member('PHID-USER-bystring');
  $project->remove_member($unlinked->{phid});
  $project->set_policy('view', 'PHID-PLCY-view');
  $project->set_policy('edit', 'PHID-PLCY-edit');

  $conduit->reset_calls;
  $project->update;
  my ($edit) = $conduit->calls('project.edit');
  is($edit->{objectIdentifier}, $exact->{phid}, 'update targets the project');
  is_deeply(
    $edit->{transactions},
    [
      {type => 'name',           value => 'renamed'},
      {type => 'description',    value => 'new description'},
      {type => 'members.add',    value => [$bob_phab->{phid}, 'PHID-USER-bystring']},
      {type => 'members.remove', value => [$unlinked->{phid}]},
      {type => 'view',           value => 'PHID-PLCY-view'},
      {type => 'edit',           value => 'PHID-PLCY-edit'},
    ],
    'update transactions'
  );
}

# set_members replaces add/remove
{
  my $project = Project->new(dclone($exact));
  $project->add_member('PHID-USER-ignored');
  $project->remove_member('PHID-USER-ignored-too');
  $project->set_members([$alice_phab->{phid}, 'PHID-USER-other']);

  $conduit->reset_calls;
  $project->update;
  my ($edit) = $conduit->calls('project.edit');
  is_deeply(
    $edit->{transactions},
    [{type => 'members.set', value => [$alice_phab->{phid}, 'PHID-USER-other']}],
    'members.set is sent instead of members.add/members.remove'
  );
}

# An update with no pending changes still calls project.edit
{
  my $project = Project->new(dclone($longer));
  $conduit->reset_calls;
  $project->update;
  my ($edit) = $conduit->calls('project.edit');
  is_deeply($edit->{transactions}, [],
    'no-op update sends an empty transaction list');
}

# The join policy set by the group sync is not sent
{
  my $project = Project->new(dclone($longer));
  $project->set_policy('join', 'PHID-PLCY-join');
  $conduit->reset_calls;
  $project->update;
  my ($edit) = $conduit->calls('project.edit');

TODO: {
    local $TODO = 'Project::update only sends view and edit policies';
    ok(
      (grep { $_->{type} eq 'join' } @{$edit->{transactions}}),
      'set_policy("join") produces a join transaction'
    );
  }
}

# Errors from project.edit propagate
{
  my $project = Project->new(dclone($longer));
  $project->set_name('will fail');
  $conduit->queue('project.edit' => http_error(500));
  throws_error(
    sub { $project->update },
    'bugzilla.code.phabricator_api_error',
    'project.edit HTTP error propagates'
  );

  $conduit->queue('project.search' => network_error('Connection refused'));
  like(
    dies { Project->new_from_query({name => $name}) },
    qr/Connection refused/,
    'network error during project.search'
  );
}

$env->finish;
done_testing;
