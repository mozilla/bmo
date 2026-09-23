#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# A user who can see a security-restricted bug only through a role (assignee or
# QA contact), and who is not a member of the restricting group, must not be
# able to remove that group by bundling a product change into the same update.
# The group stays valid in both products, so this is an explicit declassification
# rather than the automatic cleanup of a group that became invalid (Bug 2062223).

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::User;
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_TEST);

my $admin = Bugzilla::User->check({id => 1});
Bugzilla->set_user($admin);

my @products = Bugzilla::Product->get_all;
plan skip_all => 'Need at least 2 products' if @products < 2;

my ($prod_a, $prod_b) = @products[0, 1];
plan skip_all => 'BMO extension with default_security_group required'
  unless $prod_a->can('default_security_group');

# ERROR_MODE_TEST dies with a Dumper() of the error vars, so the error code
# itself is matchable -- 'something threw' would also pass for an unrelated
# failure such as an invalid version in the target product.
my $DENIED = qr/group_invalid_removal/;

my $dbh = Bugzilla->dbh;
my $pid = $$;

###############################################################################
# Fixtures
###############################################################################

# Valid in both products (membercontrol Shown), and Shown for non-members in
# both. This is the shape the report relies on: the group never becomes invalid,
# so nothing is removed automatically.
my $g_both = Bugzilla::Group->create({
  name        => "test-declass-both-$pid",
  description => 'Temp security group valid in both products (Bug 2062223)',
  isbuggroup  => 1,
});

# Valid in the source product only, so a move to the target drops it. This is
# the legitimate automatic-cleanup path that must keep working.
my $g_a_only = Bugzilla::Group->create({
  name        => "test-declass-src-$pid",
  description => 'Temp security group valid in source product (Bug 2062223)',
  isbuggroup  => 1,
});

my $SHOWN = CONTROLMAPSHOWN;
for my $prod ($prod_a, $prod_b) {
  $dbh->do(
    'INSERT IGNORE INTO group_control_map
       (group_id, product_id, entry, membercontrol, othercontrol, canedit)
     VALUES (?, ?, 0, ?, ?, 0)', undef, $g_both->id, $prod->id, $SHOWN, $SHOWN
  );
}
$dbh->do(
  'INSERT IGNORE INTO group_control_map
     (group_id, product_id, entry, membercontrol, othercontrol, canedit)
   VALUES (?, ?, 0, ?, ?, 0)', undef, $g_a_only->id, $prod_a->id, $SHOWN, $SHOWN
);

# Point the target product's default security group at a group the attacker is
# allowed to add, so the "drop invalid group" path can re-restrict the bug.
my ($orig_sec_b) = $dbh->selectrow_array(
  'SELECT security_group_id FROM products WHERE id = ?', undef, $prod_b->id);
$dbh->do('UPDATE products SET security_group_id = ? WHERE id = ?',
  undef, $g_both->id, $prod_b->id);

# The admin is a member of the restricting group; the attacker is not.
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, 0)', undef, $admin->id, $g_both->id);
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, 0)', undef, $admin->id, $g_a_only->id);

my $attacker = test_user("declass-attacker-$pid\@mozilla.bugs");

flush_caches();
$prod_a = Bugzilla::Product->new({id => $prod_a->id});
$prod_b = Bugzilla::Product->new({id => $prod_b->id});

###############################################################################
# Helpers
###############################################################################

sub test_user {
  my ($login) = @_;
  my $user = Bugzilla::User->new({name => $login});
  return $user if $user;
  return Bugzilla::User->create({
    login_name    => $login,
    realname      => $login,
    cryptpassword => 'declass-test-passw0rd!',
    disabledtext  => '',
    disable_mail  => 1,
  });
}

# Product objects cache user-specific data (groups_available, groups_mandatory),
# so the cache has to be dropped whenever the acting user changes.
sub flush_caches {
  Bugzilla::Product->object_cache_clearall();
  Bugzilla::Group->object_cache_clearall();
  Bugzilla::User->object_cache_clearall();
  Bugzilla->memcached->clear({table => 'products', id => $prod_a->id});
  Bugzilla->memcached->clear({table => 'products', id => $prod_b->id});
  Bugzilla->memcached->clear_config();
}

sub as_user {
  my ($user) = @_;
  Bugzilla->set_user(Bugzilla::User->new({id => $user->id}));
  flush_caches();
}

sub make_bug {
  my (%args) = @_;
  as_user($admin);
  my $bug = Bugzilla::Bug->create({
    short_desc   => $args{summary},
    product      => $prod_a->name,
    component    => $prod_a->components->[0]->name,
    bug_type     => 'defect',
    bug_severity => 'normal',
    op_sys       => 'Unspecified',
    rep_platform => 'Unspecified',
    version      => $prod_a->versions->[0]->name,
    groups       => [$args{group}],
    assigned_to  => $args{assigned_to},
    ($args{qa_contact} ? (qa_contact => $args{qa_contact}) : ()),
  });
  return $bug->id;
}

sub group_names {
  my ($bug_id) = @_;
  return [map { $_->name } @{Bugzilla::Bug->new({id => $bug_id})->groups_in}];
}

sub in_group {
  my ($bug_id, $name) = @_;
  return (grep { $_ eq $name } @{group_names($bug_id)}) ? 1 : 0;
}

# Runs set_all + update, returning the error (or undef on success).
sub try_update {
  my ($bug_id, $fields) = @_;
  my $err = undef;
  eval {
    my $bug = Bugzilla::Bug->check({id => $bug_id});
    $bug->set_all($fields);
    $bug->update();
    $dbh->bz_commit_transaction() if $dbh->bz_in_transaction();
    1;
  } or do {
    $err = $@ || 'unknown error';
    $dbh->bz_rollback_transaction() if $dbh->bz_in_transaction();
  };
  return $err;
}

# Group membership across a set of bugs, as the verify-new-product page sees it.
sub group_status {
  return Bugzilla::Bug->get_group_membership_status({bug_ids => [@_]});
}

sub move_fields {
  return (
    product   => $prod_b->name,
    component => $prod_b->components->[0]->name,
    version   => $prod_b->versions->[0]->name,
  );
}

###############################################################################
# 1. Non-member assignee cannot declassify by bundling a product change
###############################################################################

my $bug_id = make_bug(
  summary     => 'Bug 2062223 - assignee declassification',
  group       => $g_both->name,
  assigned_to => $attacker->login,
);
ok($bug_id, "Created restricted bug $bug_id in " . $prod_a->name);

as_user($attacker);
ok(!Bugzilla->user->in_group($g_both->name),
  'Attacker is NOT a member of the security group');
ok(Bugzilla->user->can_see_bug($bug_id),
  'Attacker can see the bug through the assignee role');

# Negative control: removal without a product change has always been denied.
my $err = try_update($bug_id, {groups => {remove => [$g_both->name]}});
like($err, $DENIED, 'Removal without a product change is denied');
ok(in_group($bug_id, $g_both->name),
  'Security group survives the removal-only attempt');

# The attack: same removal, bundled with a real product change.
$err = try_update($bug_id, {move_fields(), groups => {remove => [$g_both->name]}});
like($err, $DENIED, 'Removal bundled with a product change is denied');
ok(in_group($bug_id, $g_both->name),
  'Security group survives the product-change + removal attempt');

###############################################################################
# 2. Same attack through the QA contact role
###############################################################################

SKIP: {
  skip 'useqacontact is disabled', 3 unless Bugzilla->params->{useqacontact};

  my $qa_bug_id = make_bug(
    summary     => 'Bug 2062223 - QA contact declassification',
    group       => $g_both->name,
    assigned_to => $admin->login,
    qa_contact  => $attacker->login,
  );

  as_user($attacker);
  ok(Bugzilla->user->can_see_bug($qa_bug_id),
    'Attacker can see the bug through the QA contact role');

  my $qa_err
    = try_update($qa_bug_id, {move_fields(), groups => {remove => [$g_both->name]}});
  like($qa_err, $DENIED,
    'QA contact removal bundled with a product change is denied');
  ok(in_group($qa_bug_id, $g_both->name),
    'Security group survives the QA contact attempt');
}

###############################################################################
# 3. A group member may still remove the group during a product change
###############################################################################

my $member_bug_id = make_bug(
  summary     => 'Bug 2062223 - member removal still allowed',
  group       => $g_both->name,
  assigned_to => $admin->login,
);

as_user($admin);
$err = try_update($member_bug_id,
  {move_fields(), groups => {remove => [$g_both->name]}});
is($err, undef, 'Group member can remove the group during a product change')
  or diag($err);
ok(!in_group($member_bug_id, $g_both->name),
  'Group member successfully removed the security group');

###############################################################################
# 4. Automatic cleanup of a group invalid in the target product still works
###############################################################################

my $cleanup_bug_id = make_bug(
  summary     => 'Bug 2062223 - automatic invalid-group cleanup',
  group       => $g_a_only->name,
  assigned_to => $attacker->login,
);

as_user($attacker);
$err = try_update($cleanup_bug_id, {move_fields()});
is($err, undef,
  'Non-member assignee can move a bug whose group is invalid in the target')
  or diag($err);
ok(!in_group($cleanup_bug_id, $g_a_only->name),
  'Group invalid in the target product is removed automatically');
ok(in_group($cleanup_bug_id, $g_both->name),
  "Target product's default security group is added, keeping the bug restricted");

###############################################################################
# 5. A Mandatory group in the target product cannot be removed by anyone
###############################################################################

my $g_mandatory = Bugzilla::Group->create({
  name        => "test-declass-mandatory-$pid",
  description => 'Temp mandatory security group (Bug 2062223)',
  isbuggroup  => 1,
});
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, 0)', undef, $admin->id, $g_mandatory->id
);

# Settable in the source product, Mandatory in the target. Wired up only now so
# it does not become mandatory for the bugs used by the earlier cases.
$dbh->do(
  'INSERT IGNORE INTO group_control_map
     (group_id, product_id, entry, membercontrol, othercontrol, canedit)
   VALUES (?, ?, 0, ?, ?, 0)', undef, $g_mandatory->id, $prod_a->id, $SHOWN,
  $SHOWN
);

as_user($admin);
my $mand_bug_id = make_bug(
  summary     => 'Bug 2062223 - mandatory group removal',
  group       => $g_mandatory->name,
  assigned_to => $admin->login,
);

my $MANDATORY = CONTROLMAPMANDATORY;
$dbh->do(
  'INSERT IGNORE INTO group_control_map
     (group_id, product_id, entry, membercontrol, othercontrol, canedit)
   VALUES (?, ?, 0, ?, ?, 0)', undef, $g_mandatory->id, $prod_b->id,
  $MANDATORY, $MANDATORY
);
as_user($admin);
$prod_b = Bugzilla::Product->new({id => $prod_b->id});
ok(Bugzilla->user->in_group($g_mandatory->name),
  'Acting user IS a member of the mandatory group');

$err = try_update($mand_bug_id,
  {move_fields(), groups => {remove => [$g_mandatory->name]}});
like($err, $DENIED,
  'A group that is Mandatory in the target cannot be removed at all');
ok(in_group($mand_bug_id, $g_mandatory->name),
  'Mandatory group survives the removal attempt by a group member');

###############################################################################
# 6. Multi-bug moves report per-group membership across every selected bug
#
# The verify-new-product page moves every bug in the list, not just the one it
# renders, so it needs to know which groups are held by all / only some of them.
# 'some' is what stops the page from offering a single checkbox whose removal
# would silently declassify the bugs that do hold the group.
###############################################################################

as_user($admin);
my $multi_a = make_bug(
  summary     => 'Bug 2062223 - multi-bug move, group on this bug only',
  group       => $g_both->name,
  assigned_to => $admin->login,
);
my $multi_b = make_bug(
  summary     => 'Bug 2062223 - multi-bug move, different group',
  group       => $g_a_only->name,
  assigned_to => $admin->login,
);

is_deeply(group_status(), {}, 'No bugs means no group status');

my $status = group_status($multi_a);
is($status->{$g_both->id},
  'all', 'A single bug in the group reports the group as held by all');

$status = group_status($multi_a, $multi_b);
is($status->{$g_both->id},
  'some', 'Group held by only one of the selected bugs reports "some"');
is($status->{$g_a_only->id},
  'some', 'Group held by only the other selected bug also reports "some"');

$err = try_update($multi_b, {groups => {add => [$g_both->name]}});
is($err, undef, 'Group member can add the group to the second bug')
  or diag($err);

$status = group_status($multi_a, $multi_b);
is($status->{$g_both->id},
  'all', 'Group held by every selected bug reports "all"');
is($status->{$g_a_only->id},
  'some', 'The other group is still held by only one bug');

###############################################################################
# Cleanup
###############################################################################

as_user($admin);
$dbh->do('DELETE FROM user_group_map WHERE group_id = ?', undef,
  $g_mandatory->id);
$dbh->do('DELETE FROM group_control_map WHERE group_id = ?',
  undef, $g_mandatory->id);
$dbh->do('DELETE FROM bug_group_map WHERE group_id = ?', undef,
  $g_mandatory->id);
$g_mandatory->remove_from_db();

$dbh->do('UPDATE products SET security_group_id = ? WHERE id = ?',
  undef, $orig_sec_b, $prod_b->id);
for my $gid ($g_both->id, $g_a_only->id) {
  $dbh->do('DELETE FROM user_group_map WHERE group_id = ?',   undef, $gid);
  $dbh->do('DELETE FROM group_control_map WHERE group_id = ?', undef, $gid);
  $dbh->do('DELETE FROM bug_group_map WHERE group_id = ?',    undef, $gid);
}
$g_both->remove_from_db();
$g_a_only->remove_from_db();
flush_caches();

done_testing();
