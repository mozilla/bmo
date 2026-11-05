# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;

use Test::More "no_plan";

use QA::Util;

my ($sel, $config) = get_selenium();

log_in($sel, $config, 'admin');
set_parameters($sel,
  {"Administrative Policies" => {"allowuserdeletion-on" => undef}});

# flag_activity.requestee_id keeps a user from being deleted, so the
# confirmation page must not offer it.
my $dbh = Bugzilla->dbh;
$dbh->do("INSERT INTO profiles (login_name, realname, cryptpassword)
          VALUES ('requestee\@selenium.bugzilla.org', 'Requestee', '*')");
my $user_id = $dbh->bz_last_key('profiles', 'userid');
my ($admin_id) = $dbh->selectrow_array(
  'SELECT userid FROM profiles WHERE login_name = ?',
  undef, $config->{admin_user_login});
my ($bug_id)  = $dbh->selectrow_array('SELECT MIN(bug_id) FROM bugs');
my ($type_id) = $dbh->selectrow_array('SELECT MIN(id) FROM flagtypes');
$dbh->do(
  "INSERT INTO flag_activity
     (flag_when, type_id, flag_id, setter_id, who, requestee_id, bug_id, status)
   VALUES (NOW(), ?, 0, ?, ?, ?, ?, 'X')", undef, $type_id, $admin_id, $admin_id,
  $user_id, $bug_id
);

# The page has its verdict only if there is also something safe to report.
$dbh->do('INSERT INTO cc (bug_id, who) VALUES (?, ?)', undef, $bug_id, $user_id);

$sel->open_ok("/editusers.cgi?action=del&userid=$user_id");
$sel->is_text_present_ok('named in the flag history');
$sel->is_text_present_ok('You cannot delete this user account');

$dbh->do('DELETE FROM cc WHERE who = ?', undef, $user_id);
$dbh->do('DELETE FROM flag_activity WHERE requestee_id = ?', undef, $user_id);
$dbh->do('DELETE FROM profiles WHERE userid = ?', undef, $user_id);

logout($sel);
