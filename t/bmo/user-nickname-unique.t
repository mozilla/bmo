#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 2089200: "no nickname" is stored as NULL rather than '', so the
# database can enforce unique nicknames with a UNIQUE index.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Test::Util qw(create_user);
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $dbh = Bugzilla->dbh;
Bugzilla->set_user(Bugzilla::User->check({id => 1}));

sub stored_nickname {
  my ($user) = @_;
  my ($nick)
    = $dbh->selectrow_array('SELECT nickname FROM profiles WHERE userid = ?',
    undef, $user->id);
  return $nick;
}

is($dbh->bz_index_info('profiles', 'profiles_nickname_idx')->{TYPE},
  'UNIQUE', 'profiles_nickname_idx is UNIQUE');

my ($empty)
  = $dbh->selectrow_array("SELECT COUNT(*) FROM profiles WHERE nickname = ''");
is($empty, 0, "no profile stores '' as its nickname");

# The test DB is shared and not reset between runs, so the nickname is
# unique to this run and the users are reset to no nickname at the end.
my $run   = time . $$;
my $nick  = "nickuniq$run";
my $alice = create_user('nickname-unique-alice@mozilla.example', '*');
my $bob   = create_user('nickname-unique-bob@mozilla.example',   '*');

foreach my $user ($alice, $bob) {
  $user->set_name('No Nick');
  $user->update();
}
is(stored_nickname($alice), undef, 'a user without a nickname stores NULL');
is(stored_nickname($bob), undef,
  'a second user without a nickname also stores NULL');
is($alice->nick, 'nickname-unique-alice',
  'nick() still falls back to the login when nickname is NULL');

my $new = create_user("nickname-unique-new-$run\@mozilla.example",
  '*', realname => 'Brand New');
is(stored_nickname($new), undef,
  'a new user without a nickname is created with NULL');

$alice->set_name("Alice [:$nick]");
$alice->update();
is(stored_nickname($alice), $nick, 'a nickname is taken from the real name');

$bob->set_name("Bob [:$nick]");
$bob->update();
is(stored_nickname($bob), undef,
  'a nickname already in use is not given to a second user');

ok(
  !eval {
    $dbh->do('UPDATE profiles SET nickname = ? WHERE userid = ?',
      undef, $nick, $bob->id);
    1;
  },
  'the database rejects a duplicate nickname'
);

# A concurrent save can pass _generate_nickname's COUNT(*) check before the
# other commits. Simulate losing that race: the saves must still succeed,
# falling back to no nickname instead of dying on the duplicate key.
my $raced;
{
  no warnings 'redefine';
  local *Bugzilla::User::_generate_nickname = sub {$nick};

  $bob->set_name("Bob [:$nick]");
  ok(eval { $bob->update(); 1 }, 'losing the race on update does not die')
    or diag $@;
  is(stored_nickname($bob), undef, 'the update falls back to NULL');
  is($bob->{nickname}, undef, 'the object matches what was stored');

  $raced = eval {
    create_user("nickname-unique-raced-$run\@mozilla.example",
      '*', realname => "Raced [:$nick]");
  };
  ok($raced, 'losing the race on create does not die') or diag $@;
  is(stored_nickname($raced), undef, 'the create falls back to NULL')
    if $raced;
}
is(stored_nickname($alice), $nick, 'the winner keeps the nickname');

my ($audit) = $dbh->selectrow_array(
  "SELECT COUNT(*) FROM audit_log WHERE class = 'Bugzilla::User'
     AND object_id = ? AND field = 'nickname'", undef, $alice->id
);
ok($audit, 'nickname changes are still audit logged');

# Saving a user who already has a nickname takes a different path through
# _update_nickname than a first assignment, so cover changing and clearing one.
my $renamed = "nickrenamed$run";
$alice->set_name("Alice [:$renamed]");
my $changes = eval { $alice->update() };
ok($changes, 'changing an existing nickname does not die') or diag $@;
is(stored_nickname($alice), $renamed, 'the changed nickname is stored');
is_deeply(
  $changes->{nickname},
  [$nick, $renamed],
  'the nickname change is reported in the changes hash'
);

$alice->set_name('Alice');
$changes = eval { $alice->update() };
ok($changes, 'clearing an existing nickname does not die') or diag $@;
is(stored_nickname($alice), undef, 'the cleared nickname is stored as NULL');
is_deeply(
  $changes->{nickname},
  [$renamed, undef],
  'the cleared nickname is reported in the changes hash'
);

my @cleanup = map { $_->id } grep {defined} $alice, $bob, $new, $raced;
$dbh->do(
  'UPDATE profiles SET nickname = NULL WHERE userid IN ('
    . join(',', ('?') x @cleanup) . ')',
  undef, @cleanup
);

done_testing;
