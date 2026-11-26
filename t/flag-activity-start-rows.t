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
use Bugzilla::Attachment;
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
    'SELECT COUNT(*) FROM flag_activity WHERE flag_id = ?',
    undef, $flag->id
  ),
  1,
  'one starting row, however many times checksetup runs'
);

sub flag_history {
  my ($activity) = Bugzilla::Bug::GetBugActivity($bug_id);
  my @history;
  foreach my $operation (@$activity) {
    push @history,
      map {"$operation->{when}: $_->{removed} -> $_->{added}"}
      grep { $_->{fieldname} eq 'flagtypes.name' } @{$operation->{changes}};
  }
  return \@history;
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
my ($undated)
  = grep { $_->status eq '?' } @{Bugzilla::Bug->new($bug_id)->flags};
$dbh->do('DELETE FROM flag_activity WHERE flag_id = ?', undef, $undated->id);
$dbh->do('UPDATE flags SET modification_date = NULL WHERE id = ?',
  undef, $undated->id);

add_start_rows();
is(
  scalar $dbh->selectrow_array(
    'SELECT flag_when FROM flag_activity WHERE flag_id = ?',
    undef, $undated->id
  ),
  scalar $dbh->selectrow_array(
    'SELECT creation_date FROM flags WHERE id = ?',
    undef, $undated->id
  ),
  'a flag without a modification date is dated at its creation'
);

# Once the cutoff is set, checksetup doesn't walk the flags again.
$dbh->do('DELETE FROM flag_activity WHERE flag_id = ?', undef, $undated->id);
Bugzilla::Install::DB::_add_flag_activity_start_rows();
is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE flag_id = ?',
    undef, $undated->id
  ),
  0,
  'the start rows are only added once'
);

# An attachment flag: the starting row copies each column from the flag.
my $attach_id = Bugzilla::Attachment->create({
  bug         => Bugzilla::Bug->new($bug_id),
  creation_ts => '2099-01-01 13:00:00',
  data        => 'patch',
  description => 'Attachment with a flag',
  filename    => 'patch.txt',
  ispatch     => 0,
  isprivate   => 0,
  mimetype    => 'text/plain',
})->id;
my $requestee = Bugzilla::User->new({name => 'bob@bmo.test'});
$dbh->do(
  "INSERT INTO flags (type_id, status, bug_id, attach_id, creation_date,
                      modification_date, setter_id, requestee_id)
   VALUES (?, '?', ?, ?, '2099-01-01 13:00:00', '2099-01-01 14:00:00', ?, ?)",
  undef, $needinfo_id, $bug_id, $attach_id, $setter->id, $requestee->id
);
my $attach_flag_id = $dbh->bz_last_key('flags', 'id');

add_start_rows();
is(
  $dbh->selectrow_hashref(
    'SELECT flag_when, type_id, setter_id, who, requestee_id, bug_id,
            attachment_id, status
       FROM flag_activity WHERE flag_id = ?', undef, $attach_flag_id
  ),
  {
    flag_when     => '2099-01-01 14:00:00',
    type_id       => $needinfo_id,
    setter_id     => $setter->id,
    who           => $setter->id,
    requestee_id  => $requestee->id,
    bug_id        => $bug_id,
    attachment_id => $attach_id,
    status        => '?',
  },
  'the starting row of an attachment flag has its columns'
);

# Requestees named in the flag history can still be deleted. On a database
# where the requestee foreign key has no ON DELETE rule, checksetup adds it.
$dbh->bz_alter_fk('flag_activity', 'requestee_id',
  {TABLE => 'profiles', COLUMN => 'userid'});
Bugzilla::Install::DB->update_table_definitions({});
is($dbh->bz_fk_info('flag_activity', 'requestee_id')->{DELETE},
  'SET NULL', 'the requestee foreign key sets NULL on delete');

my $gone = create_user('gone@bmo.test', '*');
$dbh->do(
  "INSERT INTO flag_activity
     (flag_when, type_id, flag_id, setter_id, who, requestee_id, bug_id, status)
   VALUES ('2099-01-01 15:00:00', ?, ?, ?, ?, ?, ?, 'X')", undef, $needinfo_id,
  $attach_flag_id, $setter->id, $setter->id, $gone->id, $bug_id
);
my $row_id = $dbh->bz_last_key('flag_activity', 'id');
ok(eval { $dbh->do('DELETE FROM profiles WHERE userid = ?', undef, $gone->id) },
  'a requestee named in the flag history can be deleted')
  or diag $@;
is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE id = ? AND requestee_id IS NULL',
    undef, $row_id
  ),
  1,
  'and the history row is kept without the requestee'
);

done_testing;
