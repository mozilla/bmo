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
use Bugzilla::Test::Util qw(create_bug create_user);
use Bugzilla::Bug;
use Bugzilla::Install::DB;
use Bugzilla::User;
use Test2::V0;

# Redirecting a request keeps the original setter, but flag_activity.who and
# the bug history record the user who redirected it.

create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

my $requester  = create_user('requester@bmo.test',  '*');
my $redirector = create_user('redirector@bmo.test', '*');
create_user($_, '*') for qw(bob@bmo.test carol@bmo.test);

my $bug_id = create_bug(
  short_desc  => 'Flag redirect test bug',
  comment     => 'Bug for the flag_activity who tests',
  bug_type    => 'defect',
  assigned_to => 'nobody@mozilla.org',
)->id;
my ($needinfo_id)
  = $dbh->selectrow_array("SELECT id FROM flagtypes WHERE name = 'needinfo'");

Bugzilla->set_user($requester);
my $bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([],
  [{type_id => $needinfo_id, status => '?', requestee => 'bob@bmo.test'}]);
$bug->update('2026-01-01 10:00:00');

Bugzilla->set_user($redirector);
$bug = Bugzilla::Bug->new($bug_id);
my ($flag) = @{$bug->flags};
$bug->set_flags([{id => $flag->id, status => '?', requestee => 'carol@bmo.test'}],
  []);
$bug->update('2026-01-01 11:00:00');

$flag = Bugzilla::Flag->new($flag->id);
is($flag->setter_id, $requester->id, 'the setter is kept on redirect');

my $rows = $dbh->selectall_arrayref(
  'SELECT setter_id, who FROM flag_activity WHERE flag_id = ? ORDER BY id',
  {Slice => {}}, $flag->id);
is(
  $rows,
  [
    {setter_id => $requester->id, who => $requester->id},
    {setter_id => $requester->id, who => $redirector->id},
  ],
  'who is the user who made each change'
);

my ($operations) = Bugzilla::Bug::GetBugActivity($bug_id);
my ($redirect) = grep {
  grep { $_->{fieldname} eq 'flagtypes.name' && $_->{added} =~ /carol/ }
    @{$_->{changes}}
} @$operations;
is($redirect->{who}, 'redirector@bmo.test', 'history shows the redirector');

# A checksetup that died after adding the column left it nullable: the next
# one finishes the job.
$dbh->bz_alter_column('flag_activity', 'who',
  {TYPE => 'INT3', REFERENCES => {TABLE => 'profiles', COLUMN => 'userid'}});
$dbh->do('UPDATE flag_activity SET who = NULL WHERE flag_id = ?',
  undef, $flag->id);
Bugzilla::Install::DB::_add_flag_activity_who();
is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE who IS NULL'),
  0,
  'an interrupted migration fills the rows left'
);
ok($dbh->bz_column_info('flag_activity', 'who')->{NOTNULL},
  'and makes the column NOT NULL');

done_testing;
