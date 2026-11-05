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
use Bugzilla::Test::MockParams (mail_delivery_method => 'None');
use Bugzilla::Test::Util qw(create_bug create_user set_flag_activity_cutoff);
use Bugzilla::Bug;
use Bugzilla::Install::DB;
use Bugzilla::User;
use Test2::V0;

# A flag last changed before flag_activity logged its type gets a starting
# row, so that its next change shows the previous value.

create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

my $setter = create_user('setter@bmo.test', '*');
create_user('bob@bmo.test', '*');
my ($needinfo_id)
  = $dbh->selectrow_array("SELECT id FROM flagtypes WHERE name = 'needinfo'");
my ($fieldid)
  = $dbh->selectrow_array(
  "SELECT id FROM fielddefs WHERE name = 'flagtypes.name'");

my $bug_id = create_bug(
  short_desc  => 'Flag activity start rows test bug',
  comment     => 'Bug for the flag activity start rows tests',
  bug_type    => 'defect',
  assigned_to => 'nobody@mozilla.org',
)->id;

# Future dates, so that the changes come after the bug creation.
Bugzilla->set_user($setter);
my $bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([],
  [{type_id => $needinfo_id, status => '?', requestee => 'bob@bmo.test'}]);
$bug->update('2099-01-01 10:00:00');
my ($flag) = @{Bugzilla::Bug->new($bug_id)->flags};

# As if it had been set before flag_activity logged it.
$dbh->do('DELETE FROM flag_activity WHERE bug_id = ?', undef, $bug_id);
$dbh->do(
  'INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
   VALUES (?, ?, ?, ?, ?, ?)', undef, $bug_id, $setter->id,
  '2099-01-01 10:00:00', $fieldid, '', 'needinfo?(bob@bmo.test)'
);

# checksetup already ran on this database: forget it, so that it walks the
# flags again.
sub add_start_rows {
  $dbh->do('DELETE FROM flag_activity_migration');
  Bugzilla::Install::DB::_add_flag_activity_start_rows();
}

add_start_rows() for 1 .. 2;

# The flag was set before checksetup ran, the next change comes after.
set_flag_activity_cutoff('2099-01-01 10:30:00');
is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE flag_id = ?', undef, $flag->id
  ),
  1,
  'one starting row, however many times checksetup runs'
);

sub flag_history {
  my ($activity) = Bugzilla::Bug::GetBugActivity($bug_id);
  return [
    map {
      my $when = $_->{when};
      map {"$when: $_->{removed} -> $_->{added}"}
        grep { $_->{fieldname} eq 'flagtypes.name' } @{$_->{changes}}
    } @$activity
  ];
}

is(
  flag_history(),
  ['2099-01-01 10:00:00:  -> needinfo?(bob@bmo.test)'],
  'the starting row is not shown in the history'
);

$bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([{id => $flag->id, status => 'X'}], []);
$bug->update('2099-01-01 11:00:00');

is(
  flag_history(),
  [
    '2099-01-01 10:00:00:  -> needinfo?(bob@bmo.test)',
    '2099-01-01 11:00:00: needinfo?(bob@bmo.test) -> '
  ],
  'the next change shows the previous value'
);

# flags.modification_date can be NULL, flag_activity.flag_when can't.
$bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([],
  [{type_id => $needinfo_id, status => '?', requestee => 'bob@bmo.test'}]);
$bug->update('2099-01-01 12:00:00');
my ($undated) = grep { $_->status eq '?' } @{Bugzilla::Bug->new($bug_id)->flags};
$dbh->do('DELETE FROM flag_activity WHERE flag_id = ?', undef, $undated->id);
$dbh->do('UPDATE flags SET modification_date = NULL WHERE id = ?',
  undef, $undated->id);

add_start_rows();
is(
  scalar $dbh->selectrow_array(
    'SELECT flag_when FROM flag_activity WHERE flag_id = ?', undef, $undated->id
  ),
  scalar $dbh->selectrow_array(
    'SELECT creation_date FROM flags WHERE id = ?', undef, $undated->id
  ),
  'a flag without a modification date is dated at its creation'
);

# Once the cutoff is set, checksetup doesn't walk the flags again.
$dbh->do('DELETE FROM flag_activity WHERE flag_id = ?', undef, $undated->id);
Bugzilla::Install::DB::_add_flag_activity_start_rows();
is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE flag_id = ?', undef, $undated->id
  ),
  0,
  'the start rows are only added once'
);

done_testing;
