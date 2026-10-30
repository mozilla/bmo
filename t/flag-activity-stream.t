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
use Bugzilla::User;
use Test2::V0;

# The bug modal links each flag to the change that set it. Flags set before
# flag_activity logged their type have no row there, and are found from their
# bugs_activity change instead.

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

sub flag_activity_id {
  my ($legacy) = @_;
  Bugzilla->set_user(Bugzilla::User->super_user);
  my $bug_id = create_bug(
    short_desc  => 'Flag activity stream test bug',
    comment     => 'Bug for the flag activity stream tests',
    bug_type    => 'defect',
    assigned_to => 'nobody@mozilla.org',
  )->id;

  # A future date, so that the change comes after the bug creation.
  Bugzilla->set_user($setter);
  my $bug = Bugzilla::Bug->new($bug_id);
  $bug->set_flags([],
    [{type_id => $needinfo_id, status => '?', requestee => 'bob@bmo.test'}]);
  $bug->update('2099-01-01 10:00:00');

  if ($legacy) {
    $dbh->do('DELETE FROM flag_activity WHERE bug_id = ?', undef, $bug_id);
    $dbh->do(
      'INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
       VALUES (?, ?, ?, ?, ?, ?)', undef, $bug_id, $setter->id,
      '2099-01-01 10:00:00', $fieldid, '', 'needinfo?(bob@bmo.test)'
    );
  }

  $bug = Bugzilla::Bug->new($bug_id);
  my ($flag) = @{$bug->flags};
  return $bug->find_activity_id_for_flag($flag);
}

like(flag_activity_id(0), qr/^a\d+_\d+$/,
  'a flag is linked to its flag_activity change');
like(flag_activity_id(1), qr/^a\d+_\d+$/,
  'a flag without flag_activity rows is linked to its bugs_activity change');

done_testing;
