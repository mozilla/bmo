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
use Bugzilla::Test::MockParams (
  mail_delivery_method               => 'None',
  last_change_time_non_bot_skip_list => 'automation@bmo.tld',
);
use Bugzilla::Test::Util qw(create_bug create_user);
use Bugzilla::Bug;
use Bugzilla::User;
use Bugzilla::Extension::UserProfile::Util
  qw(last_user_activity tag_for_recount_from_bug update_statistics_by_user);
use Test2::V0;

# Flag changes are only in flag_activity, so the readers of a user's activity
# have to read it too.

my $bot = create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

my $human = create_user('human@bmo.test', '*');
create_user('bob@bmo.test', '*');

my $bug_id = create_bug(
  short_desc  => 'Flag activity user stats test bug',
  comment     => 'Bug for the flag_activity user stats tests',
  bug_type    => 'defect',
  assigned_to => 'nobody@mozilla.org',
)->id;
my ($needinfo_id)
  = $dbh->selectrow_array("SELECT id FROM flagtypes WHERE name = 'needinfo'");

# Future dates, so that the flag changes come after the bug creation.
Bugzilla->set_user($human);
my $bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([],
  [{type_id => $needinfo_id, status => '?', requestee => 'bob@bmo.test'}]);
$bug->update('2099-01-01 10:00:00');

Bugzilla->set_user($bot);
$bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([],
  [{type_id => $needinfo_id, status => '?', requestee => 'human@bmo.test'}]);
$bug->update('2099-01-01 11:00:00');

# Requesting needinfo also CCs the requestee: drop those changes, so that the
# flag changes are only in flag_activity.
$dbh->do('DELETE FROM bugs_activity WHERE bug_id = ?', undef, $bug_id);

is(Bugzilla::Bug->new($bug_id)->delta_ts_non_bot,
  '2099-01-01 10:00:00', 'the non-bot last change time counts flag changes');

is(last_user_activity($human->id),
  '2099-01-01 10:00:00', 'the last user activity counts flag changes');

$dbh->do('UPDATE profiles SET last_statistics_ts = ? WHERE userid = ?',
  undef, '2099-01-01 12:00:00', $human->id);
tag_for_recount_from_bug($bug_id);
my ($last_statistics_ts)
  = $dbh->selectrow_array(
  'SELECT last_statistics_ts FROM profiles WHERE userid = ?',
  undef, $human->id);
is($last_statistics_ts, undef, 'a flag change tags the user for a recount');

update_statistics_by_user($human->id);
my ($touched) = $dbh->selectrow_array(
  "SELECT count FROM profiles_statistics WHERE user_id = ? AND name = 'touched'",
  undef, $human->id);
is($touched, 1, 'a flag change counts as touching the bug');

sub product_count {
  return scalar $dbh->selectrow_array(
    'SELECT SUM(count) FROM profiles_statistics_products WHERE user_id = ?',
    undef, $human->id);
}
is(product_count(), 1, 'a flag change counts in the activity by product');

# An older change is in both tables: count it once.
my ($fieldid)
  = $dbh->selectrow_array(
  "SELECT id FROM fielddefs WHERE name = 'flagtypes.name'");
$dbh->do(
  'INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
   VALUES (?, ?, ?, ?, ?, ?)', undef, $bug_id, $human->id,
  '2099-01-01 10:00:00', $fieldid, '', 'needinfo?(bob@bmo.test)'
);
update_statistics_by_user($human->id);
is(product_count(), 1, 'a change in both tables is counted once');

done_testing;
