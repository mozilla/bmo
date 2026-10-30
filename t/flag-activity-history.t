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
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::User;
use Test2::V0;

# Bug history and bugmail read the flag changes made before flag_activity
# existed from bugs_activity, and only the newer ones from flag_activity.

create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

my $setter = create_user('setter@bmo.test', '*');
my $alice  = create_user('alice@bmo.test',  '*');
my $bob    = create_user('bob@bmo.test',    '*');

sub new_bug {
  return create_bug(
    short_desc  => shift,
    comment     => 'Bug for the flag_activity history tests',
    bug_type    => 'defect',
    assigned_to => 'nobody@mozilla.org',
  )->id;
}

my ($fieldid)
  = $dbh->selectrow_array(
  "SELECT id FROM fielddefs WHERE name = 'flagtypes.name'");
my ($review_id)
  = $dbh->selectrow_array("SELECT id FROM flagtypes WHERE name = 'review'");

sub add_flag_activity {
  my ($bug_id, $when, $flag_id, $who, $requestee_id, $status) = @_;
  $dbh->do(
    'INSERT INTO flag_activity
       (flag_when, type_id, flag_id, setter_id, who, requestee_id, bug_id,
        status)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)', undef, $when, $review_id, $flag_id,
    $who->id, $who->id, $requestee_id, $bug_id, $status
  );
}

# [who, removed, added] of the flag changes in bug history and in bugmail.
sub flag_changes {
  my ($bug_id) = @_;

  my ($operations) = Bugzilla::Bug::GetBugActivity($bug_id);
  my @history = map {
    my $who = $_->{who};
    map { [$who, $_->{removed}, $_->{added}] }
      grep { $_->{fieldname} eq 'flagtypes.name' } @{$_->{changes}}
  } @$operations;

  $dbh->do('UPDATE bugs SET lastdiffed = NULL WHERE bug_id = ?',
    undef, $bug_id);
  my ($diffs) = Bugzilla::BugMail::_get_diffs(Bugzilla::Bug->new($bug_id),
    '2026-12-31 00:00:00', {});
  my @mail = map { [$_->{who}->login, $_->{old}, $_->{new}] }
    grep { $_->{field_name} eq 'flagtypes.name' } @$diffs;

  return (\@history, \@mail);
}

# Legacy changes, only in bugs_activity.
my $legacy_bug = new_bug('legacy');
for my $row (
  ['2020-01-01 10:00:00', '',                      'review?(bob@bmo.test)'],
  ['2020-01-02 10:00:00', 'review?(bob@bmo.test)', ''],
  ['2020-01-03 10:00:00', '',                      'review+'],
  )
{
  $dbh->do(
    'INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
     VALUES (?, ?, ?, ?, ?, ?)', undef, $legacy_bug, $setter->id, $row->[0],
    $fieldid, $row->[1], $row->[2]
  );
}

# The last legacy change was also written to flag_activity, then the flag
# changed again once only flag_activity was written.
add_flag_activity($legacy_bug, '2020-01-03 10:00:00', 42, $setter, undef, '+');
add_flag_activity($legacy_bug, '2026-01-01 10:00:00', 42, $alice,  undef, '-');

my $expected = [
  ['setter@bmo.test', '',                      'review?(bob@bmo.test)'],
  ['setter@bmo.test', 'review?(bob@bmo.test)', ''],
  ['setter@bmo.test', '',                      'review+'],
  ['alice@bmo.test',  'review+',               'review-'],
];
my ($history, $mail) = flag_changes($legacy_bug);
is($history, $expected, 'history: each flag change once, with old value');
is($mail,    $expected, 'bugmail: each flag change once, with old value');

# A flag created and updated in one request has two rows in the same second:
# history shows the request's net change, like bugs_activity did.
my $same_second_bug = new_bug('same second');
add_flag_activity($same_second_bug, '2026-02-01 10:00:00', 43, $alice, $bob->id,
  '?');
add_flag_activity($same_second_bug, '2026-02-01 10:00:00', 43, $alice, undef,
  '+');
add_flag_activity($same_second_bug, '2026-02-02 10:00:00', 43, $setter, undef,
  '-');

$expected = [
  ['alice@bmo.test',  '',        'review+'],
  ['setter@bmo.test', 'review+', 'review-'],
];
($history, $mail) = flag_changes($same_second_bug);
is($history, $expected, 'history: one net change per request');
is($mail,    $expected, 'bugmail: one net change per request');

# A flag created and removed in one request changes nothing: neither history
# nor bugmail show it.
my $no_change_bug = new_bug('no change');
add_flag_activity($no_change_bug, '2026-03-01 10:00:00', 44, $alice, $bob->id,
  '?');
add_flag_activity($no_change_bug, '2026-03-01 10:00:00', 44, $alice, undef,
  'X');

($history, $mail) = flag_changes($no_change_bug);
is($history, [], 'history: no change for a flag created and removed');
is($mail,    [], 'bugmail: no change for a flag created and removed');

done_testing;
