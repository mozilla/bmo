#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# A user whose block_needinfo setting is 'hackbot_needinfo' only accepts
# needinfo requests from members of the hackbot-users group,
# whether they are in it directly or through a group nested in it.

use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Constants qw(ERROR_MODE_DIE GRANT_DIRECT GROUP_MEMBERSHIP);
use Bugzilla::Group;
use Bugzilla::Test::Util    qw(create_group create_user);
use Bugzilla::User::Setting qw(clear_settings_cache);

use Test::More;

# The shared database isn't reset between runs, so every fixture is unique.
my $prefix = 'nihb' . $$ . time;
my $dbh    = Bugzilla->dbh;
Bugzilla->error_mode(ERROR_MODE_DIE);
Bugzilla->set_user(Bugzilla::User->super_user);

my $hackbot_group = Bugzilla::Group->new({name => 'hackbot-users'});
ok($hackbot_group, 'checksetup created hackbot-users');
ok($hackbot_group->is_bug_group, 'hackbot-users is a bug group');
ok($hackbot_group->is_active, 'hackbot-users is active, so PhabBugz syncs it');
is(
  $dbh->selectrow_array(
    'SELECT COUNT(*) FROM group_control_map WHERE group_id = ?', undef,
    $hackbot_group->id
  ),
  0,
  'hackbot-users is in no products'
);

# The migration renames an existing non-bug group in place, keeping its id.
my $old_group = create_group("$prefix-old", isbuggroup => 0);
Bugzilla::Extension::Needinfo::_migrate_old_hackbot_group($old_group,
  "$prefix-new");
my $migrated = Bugzilla::Group->new({name => "$prefix-new"});
is($migrated && $migrated->id, $old_group->id, 'migration renames in place');
ok($migrated && $migrated->is_bug_group, 'migration makes it a bug group');

# A group nested in hackbot-users, standing in for groups such as
# mozilla-employee-confidential.
my $nested_group = create_group("$prefix-staff", isbuggroup => 0);
$dbh->do(
  'INSERT INTO group_group_map (member_id, grantor_id, grant_type)
   VALUES (?, ?, ?)', undef, $nested_group->id, $hackbot_group->id,
  GROUP_MEMBERSHIP
);

sub grant {
  my ($user, $group) = @_;
  $dbh->do(
    'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
     VALUES (?, ?, 0, ?)', undef, $user->id, $group->id, GRANT_DIRECT
  );
}

# Group membership is cached per user, so it is granted before anything reads
# the users' groups, and each user is reloaded afterwards.
my %users = map {
  $_ => create_user("$prefix-$_\@example.com", '*', realname => "Hackbot $_")
} qw(requestee direct nested outsider);
grant($users{direct}, $hackbot_group);
grant($users{nested}, $nested_group);
$_ = Bugzilla::User->new({id => $_->id}) foreach values %users;

my $requestee = $users{requestee};
$requestee->settings->{block_needinfo}->set('hackbot_needinfo');
clear_settings_cache($requestee->id);
$requestee = Bugzilla::User->new({id => $requestee->id});
is($requestee->settings->{block_needinfo}->{value},
  'hackbot_needinfo', 'requestee accepts needinfo from hackbot permitted only');

sub blocked_for {
  my ($requester) = @_;
  Bugzilla->set_user($requester);
  return $requestee->needinfo_blocked;
}

ok(!blocked_for($users{direct}),  'allowed from a direct group member');
ok(!blocked_for($users{nested}),  'allowed from a member of a nested group');
ok(!blocked_for($requestee),      'allowed from the requestee themselves');
ok(blocked_for($users{outsider}), 'blocked from a non-member');

Bugzilla->set_user($users{outsider});
eval { Bugzilla::Extension::Needinfo::_check_requestee($requestee) };
like($@, qr/hackbot-users/, 'non-member gets the hackbot error');

Bugzilla->set_user($users{direct});
eval { Bugzilla::Extension::Needinfo::_check_requestee($requestee) };
is($@, '', 'direct member gets no error');

done_testing;
