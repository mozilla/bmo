#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Regression tests for Bug 2056990: describekeywords.cgi leaked the number of
# hidden security bugs, both because the `csectype-*` family was missing from
# the security keyword list and because the keyword counts themselves were not
# filtered by group visibility.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::Keyword;
use Bugzilla::Product;
use Bugzilla::User;
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $dbh = Bugzilla->dbh;

my $admin = Bugzilla::User->check({id => 1});
Bugzilla->set_user($admin);

my ($product) = Bugzilla::Product->get_all;
plan skip_all => 'No product available'     unless $product;
plan skip_all => 'Product has no component' unless @{$product->components};
plan skip_all => 'Product has no version'   unless @{$product->versions};

###############################################################################
# is_security_keyword()
###############################################################################

# `csectype-*` is the family that regressed: the old pattern was
# /^(?:sec|csec|wsec|opsec)-/, and `csec` does not match `csectype-` because
# the alternation is anchored on the trailing hyphen.
my %expected = (
  'csectype-uaf'             => 1,
  'csectype-sandbox-escape'  => 1,
  'csectype-priv-escalation' => 1,
  'sec-critical'             => 1,
  'sec-high'                 => 1,
  'csec-high'                => 1,
  'wsec-audit'               => 1,
  'opsec-infra'              => 1,
  'csectype'                 => 0,
  'security'                 => 0,
  'sectionfoo'               => 0,
  'relnote'                  => 0,
  'perf'                     => 0,
);

foreach my $name (sort keys %expected) {
  my $keyword = bless({name => $name}, 'Bugzilla::Keyword');
  is($keyword->is_security_keyword,
    $expected{$name}, "is_security_keyword('$name') is $expected{$name}");
}

###############################################################################
# get_all_with_bug_count() only counts bugs visible to the current user
###############################################################################

my $suffix       = "bug2056990-$$";
my $keyword_name = "csectype-$suffix";
my $group_name   = "keyword-count-$suffix";

my $keyword = Bugzilla::Keyword->create({
  name        => $keyword_name,
  description => 'Temporary keyword for bug 2056990',
  is_active   => 1,
});
ok($keyword->id, "Created keyword $keyword_name");

my $group = Bugzilla::Group->create({
  name        => $group_name,
  description => 'Temporary group for bug 2056990',
  isbuggroup  => 1,
});
ok($group->id, "Created group $group_name");

$dbh->do(
  'INSERT INTO group_control_map
     (group_id, product_id, entry, membercontrol, othercontrol, canedit)
   VALUES (?, ?, 0, ?, 0, 0)', undef, $group->id, $product->id, CONTROLMAPSHOWN
);

my @bug_ids;
foreach my $which (qw(public restricted)) {
  my $bug = Bugzilla::Bug->create({
    short_desc   => "Keyword count $which bug - Bug 2056990",
    product      => $product->name,
    component    => $product->components->[0]->name,
    bug_type     => 'defect',
    bug_severity => 'normal',
    op_sys       => 'Unspecified',
    rep_platform => 'Unspecified',
    version      => $product->versions->[0]->name,
  });
  ok($bug->id, "Created $which bug " . $bug->id);
  push @bug_ids, $bug->id;

  $dbh->do('INSERT INTO keywords (bug_id, keywordid) VALUES (?, ?)',
    undef, $bug->id, $keyword->id);
  $dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
    undef, $bug->id, $group->id)
    if $which eq 'restricted';
}

sub count_for_keyword {
  my ($name) = @_;
  my ($found)
    = grep { $_->name eq $name } @{Bugzilla::Keyword->get_all_with_bug_count()};
  return $found ? $found->bug_count : undef;
}

# An anonymous (logged out) user is in no groups at all.
Bugzilla->set_user(Bugzilla::User->new());
is(count_for_keyword($keyword_name),
  1, 'Anonymous user only counts the unrestricted bug');

# A user who is a member of the restricting group sees both bugs. Use a
# freshly created user so no stale group membership can be cached for it.
my $login  = "keyword-count-$suffix\@bugzilla.test";
my $member = Bugzilla::User->create({
  login_name    => $login,
  cryptpassword => '*',
  disabledtext  => '',
  disable_mail  => 1,
});
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, ?)', undef, $member->id, $group->id, GRANT_DIRECT
);
Bugzilla->memcached->clear_all();

$member = Bugzilla::User->new({id => $member->id, cache => 0});
Bugzilla->set_user($member);
ok($member->in_group($group_name), "Test user is a member of $group_name");
is(count_for_keyword($keyword_name),
  2, 'Group member counts both the restricted and unrestricted bug');

# Keywords whose bugs are all hidden must still be listed, with a count of 0,
# rather than disappearing from the report entirely.
Bugzilla->set_user($admin);
my $hidden_keyword = Bugzilla::Keyword->create({
  name        => "csectype-hidden-$suffix",
  description => 'Temporary keyword for bug 2056990',
  is_active   => 1,
});
$dbh->do('INSERT INTO keywords (bug_id, keywordid) VALUES (?, ?)',
  undef, $bug_ids[1], $hidden_keyword->id);

Bugzilla->set_user(Bugzilla::User->new());
is(count_for_keyword($hidden_keyword->name),
  0, 'Fully hidden keyword is still listed with a count of 0');

###############################################################################
# Cleanup
###############################################################################

Bugzilla->set_user($admin);
$dbh->do('DELETE FROM keywords WHERE keywordid IN (?, ?)',
  undef, $keyword->id, $hidden_keyword->id);
$dbh->do('DELETE FROM bug_group_map WHERE group_id = ?',     undef, $group->id);
$dbh->do('DELETE FROM user_group_map WHERE group_id = ?',    undef, $group->id);
$dbh->do('DELETE FROM group_control_map WHERE group_id = ?', undef, $group->id);
$keyword->remove_from_db();
$hidden_keyword->remove_from_db();
$group->remove_from_db();
Bugzilla->memcached->clear_all();

done_testing();
