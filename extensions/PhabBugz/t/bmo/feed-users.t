#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The feed daemon's new user loop (PhabBugz::Feed::user_query): polling
# user.search from the saved cursor, skipping users without a BMO account,
# subscribing new users to the private revisions of bugs they are involved
# in, and warning about possible username squatters.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test2::Tools::Mock qw(mock);
use Test::More;

use Bugzilla::Extension::PhabBugz::Feed;
use Bugzilla::Extension::PhabBugz::Util qw(create_revision_attachment);
use PhabTest::Conduit                   qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $feed    = Bugzilla::Extension::PhabBugz::Feed->new;

my @mail;
my $mailer = mock 'Bugzilla::Extension::PhabBugz::Feed' =>
  (override => [MessageToMTA => sub { push @mail, $_[0] }]);

my @saved;
my $spy = mock 'Bugzilla::Extension::PhabBugz::Feed' =>
  (before => [save_last_id => sub { push @saved, $_[1] if $_[2] eq 'user' }]);

# Phabricator ids for this file start above the ids PhabTest::Env gives
# linked users, so the bots and earlier fixtures are never "new".
my $last_user_id = 800_000_000;

sub new_phab_user {
  my (%args) = @_;
  my $bmo = delete $args{bmo};
  $last_user_id++;
  return $conduit->add_user(user_obj(
    id => $last_user_id,
    ($bmo ? (bmo_id => $bmo->id, phid => phid_for_bmo_user($bmo->id)) : ()), %args,
  ));
}

sub start_scenario {
  $env->save_cursor('user', $last_user_id);
  @saved = ();
  @mail  = ();
  return $last_user_id;
}

sub run_users { $env->run_sync(sub { $feed->user_query }) }

# Sync disabled
{
  start_scenario();
  $env->sync_disabled_ok(sub { $feed->user_query });
}

# No cursor yet: the first page is requested without `before`
{
  $env->save_cursor('user', 0);
  $conduit->queue('user.search' => search_result([]));
  ok(!run_users(), 'user_query without a cursor');
  is_deeply(
    [$conduit->calls('user.search')],
    [{order => ['id'], attachments => {'external-accounts' => 1}}],
    'user.search without `before`'
  );
}

# No new users
{
  my $cursor = start_scenario();
  ok(!run_users(), 'user_query with no new users');
  is_deeply(
    [$conduit->calls('user.search')],
    [{
      order       => ['id'],
      attachments => {'external-accounts' => 1},
      before      => $cursor
    }],
    'user.search pages forward with `before` the saved cursor'
  );
  is($env->cursor('user'), $cursor, 'cursor unchanged');
  is_deeply(\@saved, [], 'nothing saved');
}

# New users are processed oldest first; users without a (valid) BMO
# account are skipped but still advance the cursor
{
  start_scenario();
  my $plain = new_phab_user(username => 'phabtest-noaccount');
  my $ghost
    = new_phab_user(username => 'phabtest-ghost', bmo_id => 2_000_000_000);
  my $member = $env->bmo_user('member');
  my $linked = new_phab_user(bmo => $member, username => 'phabtest-member');

  ok(!run_users(), 'user_query with three new users');
  is_deeply(
    \@saved,
    [$plain->{id}, $ghost->{id}, $linked->{id}],
    'users handled in ascending id order (Conduit returns newest first)'
  );
  is($env->cursor('user'), $linked->{id}, 'cursor saved after the last user');
  is($conduit->call_count('differential.revision.edit'),
    0, 'user without private revisions changes nothing');
}

# Only one page is read per run; the rest comes on the next run
{
  start_scenario();
  my $page_guard = $conduit->local_page_size(2);
  my @users = map { new_phab_user() } 1 .. 3;
  ok(!run_users(), 'first run');
  is($env->cursor('user'), $users[1]{id}, 'first run stops after one page');
  ok(!run_users(), 'second run');
  is($env->cursor('user'), $users[2]{id}, 'second run reads the next page');
}

# A new user is subscribed to private revisions on bugs they are involved in
{
  my $author      = $env->bmo_user('author');
  my $author_phab = $env->link_user($author);
  my $newcomer    = $env->bmo_user('newcomer');
  my $group       = $env->bug_group('users');

  my $private = $env->bug(groups => [$group], cc => [$newcomer]);
  my $public  = $env->bug(cc     => [$newcomer]);
  my $other   = $env->bug(groups => [$group]);

  my ($timestamp) = Bugzilla->dbh->selectrow_array('SELECT NOW()');
  my %revision_for;
  foreach my $bug ($private, $public, $other) {
    my $raw = $revision_for{$bug->id} = revision_obj(
      bug_id      => $bug->id,
      author_phid => $author_phab->{phid},
      view_policy => 'PHID-PLCY-private',
    );
    create_revision_attachment($bug, $conduit->load_revision($raw),
      $timestamp, $author);
  }

  start_scenario();
  my $phab
    = new_phab_user(bmo => $newcomer, username => $env->unique('newcomer'));
  ok(!run_users(), 'user_query for a user CCed on a private bug');

  my @edits = $conduit->calls('differential.revision.edit');
  is(scalar @edits, 1, 'one revision updated');
  is(
    $edits[0]{objectIdentifier},
    $revision_for{$private->id}{phid},
    'the revision on the private bug the user is CCed on'
  );
  is_deeply(
    $edits[0]{transactions},
    [{type => 'subscribers.add', value => [$phab->{phid}]}],
    'user added as a subscriber'
  );
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('differential.revision.search')],
    [{ids => [$revision_for{$private->id}{id}]}],
    'revision looked up by the id in the attachment filename'
  );

  # A failure while updating revisions stops the loop before saving the
  # cursor for that user
  my $cursor = start_scenario();
  my $again  = new_phab_user(bmo => $newcomer, username => $env->unique('again'));
  $conduit->queue(
    'differential.revision.edit' => conduit_error('ERR-CONDUIT-CORE', 'Locked'));
  ok(run_users(), 'user_query throws when a revision update fails');
  is($env->cursor('user'), $cursor, 'cursor not advanced past the failing user');
  ok(!run_users(), 'the user is processed on the next run');
  is($env->cursor('user'), $again->{id}, 'cursor advanced');
}

# Username squatting: another BMO account uses ":<phab username>"
{
  my $username = 'phabtestsq' . lc sprintf('%x%x', time, $$);
  my $owner    = $env->bmo_user('owner',    realname => "Real Owner :$username");
  my $squatter = $env->bmo_user('squatter', realname => "Not Them [:$username]");
  my $bystander
    = $env->bmo_user('bystander', realname => "Someone :${username}extra");

  start_scenario();
  new_phab_user(bmo => $owner, username => $username, realname => 'Real Owner');
  ok(!run_users(), 'user_query for a user with a squatted nick');
  is(scalar @mail, 1, 'one squatter alert sent');
  like(
    $mail[0] // '',
    qr/\Q${\ $squatter->login}\E/,
    'alert names the squatting account'
  );
  unlike(
    $mail[0] // '',
    qr/\Q${\ $bystander->login}\E/,
    'a longer nick is not a squatter'
  );

  start_scenario();
  my $clean = $env->bmo_user('clean');
  new_phab_user(bmo => $clean, username => $env->unique('unique-nick'));
  ok(!run_users(), 'user_query for a user with a unique nick');
  is(scalar @mail, 0, 'no alert');
}

# user.search failures leave the cursor alone
foreach my $case (
  ['Conduit error', conduit_error('ERR-CONDUIT-CORE', 'Database is read-only')],
  ['HTTP 502',      http_error(502)],
  ['non-JSON body', invalid_json()],
  ['network error', network_error('Inactivity timeout')],
  )
{
  my ($name, $reply) = @$case;
  my $cursor = start_scenario();
  $conduit->queue('user.search' => $reply);
  my $error = with_typed_errors(sub { run_users() });
  ok($error, "$name: user_query throws");
  is($env->cursor('user'), $cursor, "$name: cursor unchanged");
}

$env->fresh_request;
$env->finish;
done_testing;
