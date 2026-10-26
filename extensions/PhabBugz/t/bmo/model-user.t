#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::User: user.search / bugzilla.account.search lookups, paging,
# release manager checks and enabling/disabling users in Phabricator when the
# BMO account is disabled (the object_end_of_update hook).

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Config   qw(SetParam);
use Storable           qw(dclone);
use Test2::Tools::Mock qw(mock);
use Test::More;
use Test2::Tools::Exception qw(dies lives);

use Bugzilla::Extension::PhabBugz::Project;
use Bugzilla::Extension::PhabBugz::User;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

use constant PhabUser => 'Bugzilla::Extension::PhabBugz::User';

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

my $alice      = $env->bmo_user('alice');
my $alice_phab = $env->link_user($alice);
my $bob        = $env->bmo_user('bob');
my $bob_phab   = $env->link_user($bob);
my $unlinked   = $conduit->add_user(user_obj(username => 'phabtest-unlinked'));

# Constructor maps Conduit fields
{
  my $user = PhabUser->new(dclone($alice_phab));
  is($user->id,   $alice_phab->{id},               'id');
  is($user->phid, $alice_phab->{phid},             'phid');
  is($user->name, $alice_phab->{fields}{username}, 'name from fields.username');
  is($user->realname,    $alice->name, 'realname from fields.realName');
  is($user->creation_ts, 1512573120,   'creation_ts from fields.dateCreated');
  is($user->modification_ts, 1512574523,
    'modification_ts from fields.dateModified');
  is_deeply($user->roles, [qw(verified approved activated)], 'roles');
  is($user->view_policy, 'public',   'view policy');
  is($user->edit_policy, 'no-one',   'edit policy');
  is($user->bugzilla_id, $alice->id, 'bugzilla_id from the bmo external account');
  is($user->bugzilla_user->id, $alice->id, 'bugzilla_user loads the BMO user');

  my $plain = PhabUser->new(dclone($unlinked));
  ok(!defined $plain->bugzilla_id,   'no bmo external account: no bugzilla_id');
  ok(!defined $plain->bugzilla_user, 'no bmo external account: no bugzilla_user');

  my $github = user_obj();
  $github->{attachments}{'external-accounts'}{'external-accounts'}
    = [{id => '1234', type => 'github'}];
  ok(
    !defined PhabUser->new($github)->bugzilla_id,
    'only `bmo` external accounts link to BMO'
  );

  ok(
    dies { PhabUser->new({%{user_obj()}, fields => {}}) },
    'constructor rejects a user without the required fields'
  );
}

# match({phids})
{
  $conduit->reset_calls;
  my $users
    = PhabUser->match({phids => [$alice_phab->{phid}, $unlinked->{phid}]});
  is_deeply(
    [sort map { $_->phid } @$users],
    [sort $alice_phab->{phid}, $unlinked->{phid}],
    'match by phids returns both users'
  );
  is_deeply(
    [$conduit->calls('user.search')],
    [{
      constraints => {phids => [$alice_phab->{phid}, $unlinked->{phid}]},
      attachments => {'external-accounts' => 1},
    }],
    'user.search params for a phids match'
  );

  $conduit->reset_calls;
  is_deeply(PhabUser->match({phids => []}), [],
    'empty phid list matches nothing');
  is($conduit->call_count, 0, 'empty phid list makes no Conduit call');

  is(PhabUser->new_from_query({phids => ['PHID-USER-doesnotexist']}),
    undef, 'new_from_query returns undef when nothing matches');

  ok(dies { PhabUser->match({names => ['alice']}) },
    'match rejects unknown constraint keys');
}

# match() follows cursor.after until every page is fetched
{
  my $page_guard = $conduit->local_page_size(1);
  $conduit->reset_calls;
  my $users = PhabUser->match(
    {phids => [$alice_phab->{phid}, $bob_phab->{phid}, $unlinked->{phid}]});
  is(scalar @$users, 3, 'paged match returns all users');
  my @calls = $conduit->calls('user.search');
  is(scalar @calls, 3, 'one user.search call per page');
  ok(!exists $calls[0]{after},             'first page has no cursor');
  ok($calls[1]{after} && $calls[2]{after}, 'later pages send cursor.after');
}

# match({ids}) maps BMO ids to PHIDs with bugzilla.account.search
{
  Bugzilla->memcached->clear({key => 'phab_user_bugzilla_id_' . $alice->id});
  $conduit->reset_calls;
  my $user = PhabUser->new_from_query({ids => [$alice->id]});
  is($user->phid, $alice_phab->{phid}, 'match by BMO id finds the linked user');
  is_deeply(
    [$conduit->calls('bugzilla.account.search')],
    [{ids => [$alice->id]}],
    'bugzilla.account.search params'
  );
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('user.search')],
    [{phids => [$alice_phab->{phid}]}],
    'user.search for the PHID returned by bugzilla.account.search'
  );

SKIP: {
    skip 'memcached is not configured', 1 unless Bugzilla->memcached->enabled;
    $conduit->reset_calls;
    PhabUser->new_from_query({ids => [$alice->id]});
    is($conduit->call_count('bugzilla.account.search'),
      0, 'BMO id -> PHID mapping is served from memcached');
  }

  my $nobody = $env->bmo_user('not-in-phab');
  $conduit->reset_calls;
  is_deeply(PhabUser->match({ids => [$nobody->id]}),
    [], 'BMO user without a Phabricator account matches nothing');
  is($conduit->call_count('user.search'), 0, 'no user.search without PHIDs');
}

# Errors from Conduit propagate
{
  $conduit->queue('user.search' => conduit_error('ERR-CONDUIT-CORE', 'boom'));
  throws_error(
    sub { PhabUser->match({phids => [$alice_phab->{phid}]}) },
    'bugzilla.code.phabricator_api_error',
    'user.search error propagates'
  );

  Bugzilla->memcached->clear({key => 'phab_user_bugzilla_id_' . $bob->id});
  $conduit->queue('bugzilla.account.search' => http_error(503));
  throws_error(
    sub { PhabUser->match({ids => [$bob->id]}) },
    'bugzilla.code.phabricator_api_error',
    'bugzilla.account.search error propagates'
  );
}

# is_release_manager
{
  my $relman = $conduit->add_project(
    project_obj(name => 'release-managers', members => [$alice_phab->{phid}]));

  my $alice_user = PhabUser->new(dclone($alice_phab));
  my $bob_user   = PhabUser->new(dclone($bob_phab));
  $conduit->reset_calls;
  ok($alice_user->is_release_manager, 'member of #release-managers');
  ok(!$bob_user->is_release_manager,  'not a member of #release-managers');
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('project.search')],
    [{name => 'release-managers'}, {name => 'release-managers'}],
    'release-managers project looked up by name'
  );

  $conduit->reset_calls;
  ok($alice_user->is_release_manager, 'cached answer');
  is($conduit->call_count, 0, 'is_release_manager is cached on the object');

  $relman->{fields}{name} = 'release-managers-renamed';
  ok(
    !PhabUser->new(dclone($alice_phab))->is_release_manager,
    'no #release-managers project: not a release manager'
  );
  $relman->{fields}{name} = 'release-managers';
}

# set_user_enabled_status
{
  my $user = PhabUser->new(dclone($alice_phab));
  foreach my $enabled (0, 1) {
    $conduit->reset_calls;
    $user->set_user_enabled_status($enabled);
    my ($call) = $conduit->calls('user.edit');
    is($call->{objectIdentifier}, $alice_phab->{phid},
      'user.edit objectIdentifier');
    is(scalar @{$call->{transactions}}, 1,          'one transaction');
    is($call->{transactions}[0]{type},  'disabled', 'disabled transaction');
    is(
      ($call->{transactions}[0]{value} ? 1 : 0),
      ($enabled                        ? 0 : 1),
      "disabled = " . ($enabled ? 'false' : 'true') . " when enabled=$enabled"
    );
    ok(ref $call->{transactions}[0]{value}, 'value is a JSON boolean');
  }

  $conduit->queue('user.edit' => conduit_error('ERR-CONDUIT-CORE', 'nope'));
  throws_error(
    sub { $user->set_user_enabled_status(0) },
    'bugzilla.code.phabricator_api_error',
    'user.edit error propagates'
  );
}

# Disabling a BMO account disables the linked Phabricator user
{
  my @mail;
  my $mailer = mock 'Bugzilla::Extension::PhabBugz' =>
    (override => [MessageToMTA => sub { push @mail, $_[0] }]);

  my $carol      = $env->bmo_user('carol');
  my $carol_phab = $env->link_user($carol);

  $conduit->reset_calls;
  $carol->set_disabledtext('Disabled by PhabBugz test');
  $carol->update;
  my ($disable) = $conduit->calls('user.edit');
  ok($disable, 'disabling the BMO account calls user.edit');
  is($disable->{objectIdentifier}, $carol_phab->{phid}, 'for the linked user');
  ok($disable->{transactions}[0]{value}, 'disabled = true');

  $conduit->reset_calls;
  $carol->set_disabledtext('');
  $carol->update;
  my ($enable) = $conduit->calls('user.edit');
  ok(
    $enable && !$enable->{transactions}[0]{value},
    're-enabling the BMO account sets disabled = false'
  );

  $conduit->reset_calls;
  $carol->set_name('Carol Renamed');
  $carol->update;
  is($conduit->call_count('user.edit'), 0, 'other user changes are not synced');

  my $dave = $env->bmo_user('dave-no-phab');
  $conduit->reset_calls;
  $dave->set_disabledtext('Disabled by PhabBugz test');
  $dave->update;
  is($conduit->call_count('user.edit'),
    0, 'no user.edit when the BMO user has no Phabricator account');

  SetParam('phabricator_enabled', 0);
  $conduit->reset_calls;
  $carol->set_disabledtext('Disabled while sync is off');
  $carol->update;
  is($conduit->call_count, 0, 'no Conduit calls with phabricator_enabled off');
  $conduit->apply_params;
  $carol->set_disabledtext('');
  $carol->update;

  @mail = ();
  $conduit->queue('user.edit' => network_error('Connection refused'));
  ok(
    lives {
      $carol->set_disabledtext('Disabled during an outage');
      $carol->update;
    },
    'a Phabricator outage does not block the BMO update'
  );
  is(scalar @mail, 1, 'the maintainer is emailed about the failure');
  like($mail[0] // '', qr/\Q${\ $carol->login}\E/, 'email names the user');
  ok(Bugzilla::User->new($carol->id)->disabledtext,
    'the BMO account is still disabled');
}

$env->finish;
done_testing;
