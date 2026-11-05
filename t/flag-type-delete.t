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
use Bugzilla::Constants;
use Bugzilla::FlagType;
use Bugzilla::User;
use Test2::V0;

# flag_activity is the only record of flag changes, and its rows are deleted
# with their flag type: a type with some can't be deleted.

create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
Bugzilla->error_mode(ERROR_MODE_TEST);
my $dbh = Bugzilla->dbh;

my $unused = Bugzilla::FlagType->create({
  name        => 'unused',
  description => 'A flag type that is never set',
  target_type => 'bug',
});
ok(lives { $unused->remove_from_db }, 'an unused flag type can be deleted');
ok(!Bugzilla::FlagType->new($unused->id), 'it is gone');

my $setter = create_user('setter@bmo.test', '*');
create_user('bob@bmo.test', '*');
my $bug_id = create_bug(
  short_desc  => 'Flag type delete test bug',
  comment     => 'Bug for the flag type delete tests',
  bug_type    => 'defect',
  assigned_to => 'nobody@mozilla.org',
)->id;
my $needinfo = Bugzilla::FlagType->new({name => 'needinfo'});

Bugzilla->set_user($setter);
my $bug = Bugzilla::Bug->new($bug_id);
$bug->set_flags([],
  [{type_id => $needinfo->id, status => '?', requestee => 'bob@bmo.test'}]);
$bug->update();

# Even once its flags are gone, the type keeps its history.
$dbh->do('DELETE FROM flags WHERE type_id = ?', undef, $needinfo->id);

Bugzilla->set_user(Bugzilla::User->super_user);
$needinfo = Bugzilla::FlagType->new($needinfo->id);
like(dies { $needinfo->remove_from_db }, qr/flag_type_has_activity/,
  'a flag type with flag_activity rows cannot be deleted');
ok(
  $dbh->selectrow_array(
    'SELECT COUNT(*) FROM flag_activity WHERE type_id = ?', undef, $needinfo->id
  ),
  'its flag_activity rows are kept'
);

done_testing;
