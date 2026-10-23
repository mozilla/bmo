#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::Util qw(create_bug create_user);
use Bugzilla::User;
use Capture::Tiny qw(capture_stdout);
use Test2::V0;

# scripts/flag_activity_backfill.pl copies the flag changes recorded in
# bugs_activity into flag_activity, skipping the ones already there.

# super_user() resolves 'automation@bmo.tld', which the mock DB does not ship.
create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

my $setter = create_user('setter@bmo.test', '*');
my $alice  = create_user('alice@bmo.test',  '*');
my $bob    = create_user('bob@bmo.test',    '*');

my $bug_id = create_bug(
  short_desc  => 'Backfill test bug',
  comment     => 'Bug for the flag_activity backfill tests',
  bug_type    => 'defect',
  assigned_to => 'nobody@mozilla.org',
)->id;

my ($fieldid)
  = $dbh->selectrow_array(
  "SELECT id FROM fielddefs WHERE name = 'flagtypes.name'");
my ($review_id)
  = $dbh->selectrow_array("SELECT id FROM flagtypes WHERE name = 'review'");

sub add_activity {
  my ($when, $removed, $added) = @_;
  $dbh->do(
    'INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
     VALUES (?, ?, ?, ?, ?, ?)', undef, $bug_id, $setter->id, $when, $fieldid,
    $removed, $added
  );
}

# One change asks two people for review.
add_activity('2020-01-01 10:00:00',
  '', 'review?(alice@bmo.test), review?(bob@bmo.test)');

# A dual-written change, already in flag_activity with its real flag_id.
add_activity('2020-01-02 10:00:00', 'review?(alice@bmo.test)', 'review+');
$dbh->do(
  'INSERT INTO flag_activity
     (flag_when, type_id, flag_id, setter_id, requestee_id, bug_id, status)
   VALUES (?, ?, 42, ?, NULL, ?, ?)', undef, '2020-01-02 10:00:00', $review_id,
  $setter->id, $bug_id, '+'
);

# A flag cleared, asked from an account that no longer exists.
add_activity('2020-01-03 10:00:00', 'review?(gone@bmo.test)', '');

sub run_backfill {
  local @ARGV = ();
  local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /redefined/ };
  my $output = capture_stdout { do './scripts/flag_activity_backfill.pl' };
  die $@ if $@;
  return $output;
}

sub rows {
  return $dbh->selectall_arrayref(
    'SELECT flag_when, flag_id, requestee_id, status
       FROM flag_activity ORDER BY flag_when, requestee_id', {Slice => {}}
  );
}

my $output = run_backfill();
like(
  $output,
  qr/unknown requestee \(NULL inserted\): 1/,
  'the deleted requestee is counted'
);

is(
  rows(),
  [
    {
      flag_when    => '2020-01-01 10:00:00',
      flag_id      => 0,
      requestee_id => $alice->id,
      status       => '?'
    },
    {
      flag_when    => '2020-01-01 10:00:00',
      flag_id      => 0,
      requestee_id => $bob->id,
      status       => '?'
    },
    {
      flag_when    => '2020-01-02 10:00:00',
      flag_id      => 42,
      requestee_id => undef,
      status       => '+'
    },
    {
      flag_when    => '2020-01-03 10:00:00',
      flag_id      => 0,
      requestee_id => undef,
      status       => 'X'
    },
  ],
  'both requestees backfilled, the dual-written row kept once, flag_id 0'
);

run_backfill();
is(scalar @{rows()}, 4, 'a second run inserts nothing');

done_testing;
