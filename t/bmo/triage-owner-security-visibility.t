#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Regression test for Bug 2065387: a component's triage owner may see
# group-restricted bugs in that component, but only while they are also a
# member of the mozilla-employee-confidential group.
#
# The rule is implemented twice and the two copies must stay synchronized:
#
#   * Bugzilla::User::visible_bugs   - direct bug access (show_bug, REST get)
#   * Bugzilla::Search               - the security_triage join in
#                                      _standard_joins plus the matching term
#                                      in _standard_where
#
# Every case below is therefore asserted through both paths. If the join is
# ever added without the WHERE term (or vice versa) the search assertions
# break, and if either path drops the group check the negative assertions
# break.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::Search;
use Bugzilla::User;
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $dbh = Bugzilla->dbh;
my $pid = $$;

my $confidential
  = Bugzilla::Group->new({name => 'mozilla-employee-confidential'});
plan skip_all => 'mozilla-employee-confidential group required'
  unless $confidential;

my $admin = Bugzilla::User->check({id => 1});
Bugzilla->set_user($admin);

# The helpers below grant and revoke group membership through set_groups(),
# which requires the acting user to have bless rights on the group.
plan skip_all => 'admin cannot bless ' . $confidential->name
  unless $admin->can_bless($confidential->id);

my ($product) = grep { @{$_->versions} } Bugzilla::Product->get_all;
plan skip_all => 'Need a product with at least one version' unless $product;

###############################################################################
# Helpers
###############################################################################

# set_groups() checks Bugzilla->user->can_bless(), which caches its group list
# on the user object. The fixtures create a group after that cache would have
# been filled, so re-read the admin before each change.
sub as_admin {
  $admin = reload($admin);
  Bugzilla->set_user($admin);
}

# set_groups() stashes the change and update() applies it, writes the audit and
# profiles_activity rows, and invalidates the memcached group list. The admin
# group is granted bless on every group at creation time, so the admin may make
# both of these changes.
sub add_to_group {
  my ($user, $group) = @_;
  as_admin();
  my $target = reload($user);
  $target->set_groups({add => [$group->name]});
  $target->update();
}

sub remove_from_group {
  my ($user, $group) = @_;
  as_admin();
  my $target = reload($user);
  $target->set_groups({remove => [$group->name]});
  $target->update();
}

sub test_user {
  my ($login) = @_;
  my $user = Bugzilla::User->new({name => $login});
  return $user if $user;
  return Bugzilla::User->create({
    login_name    => $login,
    realname      => $login,
    cryptpassword => 'triage-owner-test-passw0rd!',
    disabledtext  => '',
    disable_mail  => 1,
  });
}

# Always re-read the user so neither the object cache, the per-object group
# list, nor the per-object _visible_bugs_cache can mask a permission change.
sub reload {
  my ($user) = @_;
  return Bugzilla::User->new({id => $user->id});
}

sub can_see {
  my ($user, $bug_id) = @_;
  return reload($user)->can_see_bug($bug_id) ? 1 : 0;
}

sub search_finds {
  my ($user, $bug_id) = @_;
  my $searcher = reload($user);
  Bugzilla->set_user($searcher);
  my $search = Bugzilla::Search->new(
    fields => ['bug_id'],
    params => {f1 => 'bug_id', o1 => 'equals', v1 => $bug_id},
    user   => $searcher,
  );
  my $found = grep { $_->[0] == $bug_id } @{$search->data};
  Bugzilla->set_user($admin);
  return $found ? 1 : 0;
}

###############################################################################
# Fixtures
###############################################################################

# The bug is restricted by a throwaway group that none of the triage owners
# belong to. Restricting it with mozilla-employee-confidential itself would let
# the triage owner in through ordinary group membership and prove nothing about
# the triage-owner rule.
my $sec_group = Bugzilla::Group->create({
  name        => "test-triage-sec-$pid",
  description => 'Temp security group for Bug 2065387 test',
  isbuggroup  => 1,
});
$dbh->do(
  'INSERT IGNORE INTO group_control_map
     (group_id, product_id, entry, membercontrol, othercontrol, canedit)
   VALUES (?, ?, 0, 1, 0, 0)', undef, $sec_group->id, $product->id
);

# The admin needs the group to be able to file the restricted bug.
add_to_group($admin, $sec_group);
as_admin();

my $owner_member    = test_user("triage-member-$pid\@triage.test");
my $owner_nonmember = test_user("triage-nonmember-$pid\@triage.test");
my $owner_other     = test_user("triage-other-$pid\@triage.test");

add_to_group($owner_member, $confidential);
add_to_group($owner_other,  $confidential);

# $owner_nonmember is deliberately left out of mozilla-employee-confidential.
remove_from_group($owner_nonmember, $confidential);

# initialowner is the admin on both components so that a triage owner never
# picks up access as the default assignee instead.
my $comp_target = Bugzilla::Component->create({
  product         => $product,
  name            => "TriageOwnerTarget-$pid",
  description     => 'Temp component for Bug 2065387 test',
  initialowner    => $admin->login,
  team_name       => 'Mozilla',
  triage_owner_id => $owner_member->login,
});
my $comp_other = Bugzilla::Component->create({
  product         => $product,
  name            => "TriageOwnerOther-$pid",
  description     => 'Temp component for Bug 2065387 test',
  initialowner    => $admin->login,
  team_name       => 'Mozilla',
  triage_owner_id => $owner_other->login,
});

my $bug = Bugzilla::Bug->create({
  short_desc   => "Triage owner visibility - Bug 2065387 - $pid",
  product      => $product->name,
  component    => $comp_target->name,
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => $product->versions->[0]->name,
  groups       => [$sec_group->name],
});

###############################################################################
# Tests
###############################################################################

ok(
  (grep { $_->name eq $sec_group->name } @{$bug->groups_in}),
  'Test bug ' . $bug->id . ' is restricted to ' . $sec_group->name
);

# --- Positive: triage owner who is in mozilla-employee-confidential ---

ok(can_see($owner_member, $bug->id),
  'Triage owner in mozilla-employee-confidential can see the restricted bug');
ok(
  search_finds($owner_member, $bug->id),
  'Triage owner in mozilla-employee-confidential finds the restricted bug via search'
);

# --- Negative: triage owner of a different component ---
#
# In mozilla-employee-confidential, but triage owner of the wrong component,
# so the join must not match.

ok(!can_see($owner_other, $bug->id),
  'Triage owner of a different component cannot see the restricted bug');
ok(
  !search_finds($owner_other, $bug->id),
  'Triage owner of a different component does not find the restricted bug via search'
);

# --- Negative: triage owner of the right component, not in the group ---

$comp_target->set_triage_owner($owner_nonmember->login);
$comp_target->update();

ok(
  !can_see($owner_nonmember, $bug->id),
  'Triage owner outside mozilla-employee-confidential cannot see the restricted bug'
);
ok(
  !search_finds($owner_nonmember, $bug->id),
  'Triage owner outside mozilla-employee-confidential does not find the restricted bug via search'
);

# --- Negative: same user and component, group membership revoked ---
#
# The strongest form of the check. Only the group membership changes between
# the passing assertions above and these, so nothing else can explain a pass.

$comp_target->set_triage_owner($owner_member->login);
$comp_target->update();
remove_from_group($owner_member, $confidential);

ok(!can_see($owner_member, $bug->id),
  'Revoking mozilla-employee-confidential revokes the triage owner bug access');
ok(
  !search_finds($owner_member, $bug->id),
  'Revoking mozilla-employee-confidential removes the bug from triage owner search results'
);

# Re-granting restores access, confirming the previous failures were caused by
# the group check and not by leftover state from set_triage_owner().
add_to_group($owner_member, $confidential);

ok(
  can_see($owner_member, $bug->id),
  'Re-granting mozilla-employee-confidential restores the triage owner bug access'
);
ok(
  search_finds($owner_member, $bug->id),
  'Re-granting mozilla-employee-confidential restores the bug in triage owner search results'
);

###############################################################################
# Cleanup
###############################################################################

Bugzilla->set_user($admin);
$bug->remove_from_db();
$comp_target->remove_from_db();
$comp_other->remove_from_db();

foreach my $user ($owner_member, $owner_nonmember, $owner_other) {
  remove_from_group($user, $confidential);
}
remove_from_group($admin, $sec_group);

$dbh->do('DELETE FROM group_control_map WHERE group_id = ?',
  undef, $sec_group->id);
$dbh->do('DELETE FROM bug_group_map WHERE group_id = ?', undef, $sec_group->id);
$sec_group->remove_from_db();

done_testing();
