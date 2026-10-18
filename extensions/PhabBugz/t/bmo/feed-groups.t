#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The feed daemon's group sync (PhabBugz::Feed::group_query): every active
# BMO bug group gets a locked down `bmo-<group>` Phabricator project whose
# members match the group (plus phab-bot and lando).
#
# The sync walks every active bug group in the shared test database, so the
# assertions only look at the projects of the groups this file creates.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test::More;

use Bugzilla::Extension::PhabBugz::Feed;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $feed    = Bugzilla::Extension::PhabBugz::Feed->new;

my $secure = $conduit->add_project(project_obj(name => 'secure-revision'));
my $bot    = $env->phab_bot_phab->{phid};
my $lando  = $env->lando_phab->{phid};

my $alice      = $env->bmo_user('alice');
my $alice_phab = $env->link_user($alice);
my $bob        = $env->bmo_user('bob');
my $bob_phab   = $env->link_user($bob);
my $carol      = $env->bmo_user('carol-not-in-phab');

my $group = $env->bug_group('sync');
$env->add_to_group($_, $group) for $alice, $carol;
my $project_name = 'bmo-' . $group->name;

sub run_groups { $env->run_sync(sub { $feed->group_query }) }

sub project_edits {
  my ($project) = @_;
  return [$conduit->transactions_for($project->{phid}, 'project.edit')];
}

sub members_of {
  my ($project) = @_;
  return [sort map { $_->{phid} } @{$project->{attachments}{members}{members}}];
}

# Sync disabled
$env->sync_disabled_ok(sub { $feed->group_query });

# First sync creates the project with locked down policies
{
  ok(!run_groups(), 'group_query creates missing projects');
  my $project = $conduit->find_project(name => $project_name);
  ok($project, "$project_name created");

  my ($create) = grep {
    !exists $_->{objectIdentifier} && $_->{transactions}[0]{value} eq $project_name
  } $conduit->calls('project.edit');
  is_deeply(
    $create->{transactions},
    [
      {type => 'name',        value => $project_name},
      {type => 'description', value => 'BMO Security Group for ' . $group->name},
      {type => 'edit',        value => $secure->{phid}},
      {type => 'join',        value => $secure->{phid}},
      {type => 'view',        value => $secure->{phid}},
      {type => 'icon',        value => 'group'},
      {type => 'color',       value => 'red'},
    ],
    'project.edit create transactions'
  );

  my ($add) = grep { $_->{type} eq 'members.add' } @{project_edits($project)};
  is_deeply(
    [sort @{$add->{value}}],
    [sort $alice_phab->{phid}, $bot, $lando],
    'group members with Phabricator accounts, phab-bot and lando added'
  );
  is_deeply(
    members_of($project),
    [sort $alice_phab->{phid}, $bot, $lando],
    'project membership matches the group'
  );

  cmp_ok(
    scalar(
      grep { ($_->{constraints}{name} // '') =~ /^bmo-/ }
        $conduit->calls('project.search')
    ),
    '>', 1,
    'the seeded bug groups are synced too'
  );
}

# Second sync with nothing changed makes no edits to the project
{
  my $project = $conduit->find_project(name => $project_name);
  ok(!run_groups(), 'group_query with membership in sync');
  is_deeply(project_edits($project), [],
    'no project.edit when membership matches');

  # The policies are only sent along with membership changes
  $project->{fields}{policy}{view} = 'public';
  ok(!run_groups(), 'group_query with a drifted view policy');
TODO: {
    local $TODO = 'group_query only updates projects whose membership changed';
    ok((grep { $_->{type} eq 'view' } @{project_edits($project)}),
      'drifted policy is reset to secure-revision');
  }
  $project->{fields}{policy}{view} = $secure->{phid};
}

# Membership drift is corrected with add/remove, and policies are re-sent
{
  my $project = $conduit->find_project(name => $project_name);
  $env->remove_from_group($alice, $group);
  $env->add_to_group($bob, $group);
  @{$project->{attachments}{members}{members}}
    = grep { $_->{phid} ne $lando } @{$project->{attachments}{members}{members}};

  ok(!run_groups(), 'group_query with membership drift');
  my %by_type = map { $_->{type} => $_->{value} } @{project_edits($project)};
  is_deeply(
    [sort @{$by_type{'members.add'}}],
    [sort $bob_phab->{phid}, $lando],
    'new group member added and lando restored'
  );
  is_deeply(
    $by_type{'members.remove'},
    [$alice_phab->{phid}],
    'former group member removed'
  );
  is($by_type{view}, $secure->{phid}, 'view policy set');
  is($by_type{edit}, $secure->{phid}, 'edit policy set');

TODO: {
    local $TODO = 'Project::update drops the join policy';
    is($by_type{join}, $secure->{phid}, 'join policy set');
  }

  is_deeply(
    members_of($project),
    [sort $bob_phab->{phid}, $bot, $lando],
    'project membership matches the group again'
  );
}

# Inactive and non-bug groups are not synced
{
  my $inactive = $env->bug_group('inactive');
  $inactive->set_is_active(0);
  $inactive->update;
  my $system = $env->group('system', isbuggroup => 0);

  ok(!run_groups(), 'group_query with inactive and system groups');
  my %searched = map { ($_->{constraints}{name} // '') => 1 }
    $conduit->calls('project.search');
  ok($searched{$project_name},             'active bug group synced');
  ok(!$searched{'bmo-' . $inactive->name}, 'inactive bug group skipped');
  ok(!$searched{'bmo-' . $system->name},   'non-bug group skipped');
}

# Missing secure-revision project
{
  $secure->{fields}{name} = 'secure-revision-renamed';
  my $error = run_groups();

  # Project->new_from_query returns a false value (not an object) here.
  like(
    $error // '',
    qr/Can't call method "phid"/,
    'group_query dies without the secure-revision project'
  );
  $secure->{fields}{name} = 'secure-revision';
}

# Conduit failures abort the sync
foreach my $case (
  ['project.search', conduit_error('ERR-CONDUIT-CORE', 'Database is read-only')],
  ['project.search', http_error(500)],
  ['project.edit',   network_error('Connection refused')],
  ['user.search',    invalid_json()],
  )
{
  my ($method, $reply) = @$case;

  # Give the sync a membership change to send for this file's group.
  $env->add_to_group($alice, $group);
  $conduit->on($method => $reply);
  my $error = with_typed_errors(sub { run_groups() });
  ok($error, "$method failure (" . ($reply->{type}) . ') aborts group_query');
  $conduit->off($method);
  $env->remove_from_group($alice, $group);
}

ok(!run_groups(), 'group_query succeeds again after the failures');

$env->fresh_request;
$env->finish;
done_testing;
