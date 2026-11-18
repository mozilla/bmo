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
my $dbh = Bugzilla->dbh;
my ($user_id, $flag_id);

# Runs even if a check below dies, so that a rerun finds a clean database.
END {
  if ($flag_id) {
    $dbh->do('DELETE FROM flag_activity WHERE flag_id = ?', undef, $flag_id);
    $dbh->do('DELETE FROM flags WHERE id = ?',              undef, $flag_id);
  }
  $dbh->do('DELETE FROM profiles WHERE userid = ?', undef, $user_id) if $user_id;
  eval {
    set_parameters($sel,
      {"Administrative Policies" => {"allowuserdeletion-off" => undef}});
    logout($sel);
  };
}

log_in($sel, $config, 'admin');
set_parameters($sel,
  {"Administrative Policies" => {"allowuserdeletion-on" => undef}});

# A user asked to set a flag, and named as requestee in the flag history, can
# be deleted: the request is cleared and the history keeps the row without
# the requestee.
my $login = 'requestee@selenium.bugzilla.org';
$dbh->do(
  "INSERT INTO profiles (login_name, realname, cryptpassword)
          VALUES (?, 'Requestee', '*')", undef, $login
);
$user_id = $dbh->bz_last_key('profiles', 'userid');
my ($admin_id)
  = $dbh->selectrow_array('SELECT userid FROM profiles WHERE login_name = ?',
  undef, $config->{admin_user_login});
my ($bug_id) = $dbh->selectrow_array('SELECT MIN(bug_id) FROM bugs');
my ($type_id)
  = $dbh->selectrow_array(
  "SELECT MIN(id) FROM flagtypes WHERE target_type = 'b'");
$dbh->do(
  "INSERT INTO flags (type_id, status, bug_id, creation_date,
                      modification_date, setter_id, requestee_id)
   VALUES (?, '?', ?, NOW(), NOW(), ?, ?)", undef, $type_id, $bug_id, $admin_id,
  $user_id
);
$flag_id = $dbh->bz_last_key('flags', 'id');
$dbh->do(
  "INSERT INTO flag_activity
     (flag_when, type_id, flag_id, setter_id, who, requestee_id, bug_id, status)
   VALUES (NOW(), ?, ?, ?, ?, ?, ?, '?')", undef, $type_id, $flag_id, $admin_id,
  $admin_id, $user_id, $bug_id
);
my $history_id = $dbh->bz_last_key('flag_activity', 'id');

$sel->open_ok("/editusers.cgi?action=del&userid=$user_id");
$sel->title_is("Confirm deletion of user $login");
ok(!$sel->is_text_present('You cannot delete this user account'),
  'The requestee can be deleted');
$sel->click_ok("delete");
$sel->wait_for_page_to_load_ok(WAIT_TIME);
$sel->title_is("User $login deleted");

is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE id = ? AND requestee_id IS NULL',
    undef, $history_id
  ),
  1,
  'The flag history keeps the row without the requestee'
);
is(
  scalar $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flags WHERE id = ? AND requestee_id IS NULL',
    undef, $flag_id
  ),
  1,
  'The request is cleared'
);
