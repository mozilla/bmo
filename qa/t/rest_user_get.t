#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to User.get()                  #
# GET /rest/user                                     #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config);
use QA::Tests qw(PRIVATE_BUG_USER);
use QA::REST::Util qw(api_headers rest_get_url);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $get_user        = $config->{'unprivileged_user_login'};
my $canconfirm_user = $config->{'canconfirm_user_login'};
my $priv_user       = $config->{PRIVATE_BUG_USER . '_user_login'};
my $disabled        = $config->{'disabled_user_login'};
my $disabled_match  = substr($disabled, 0, length($disabled) - 1);

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

my @tests = (
  {
    args => {names => [$get_user]},
    test => "Logged-out user can get unprivileged user by name"
  },
  {
    args  => {match => [$get_user]},
    test  => 'Logged-out user cannot use the match argument',
    error => 'Logged-out users cannot use',
  },
  {
    args  => {ids => [1]},
    test  => 'Logged-out users cannot use the "ids" argument',
    error => 'Logged-out users cannot use',
  },

  # match & names
  {
    user => 'unprivileged',
    args => {names => [$get_user]},
    test => "Unprivileged user can get themselves",
  },
  {
    user => 'unprivileged',
    args => {match => [$get_user]},
    test => 'Logged-in user can use the match argument',
  },
  {
    user => 'unprivileged',
    args => {match => [$get_user], names => [$get_user]},
    test => 'Specifying the same thing in "match" and "names"',
  },

  # include_disabled
  {
    user => 'unprivileged',
    args => {match => [$get_user, $disabled_match]},
    test => 'Disabled users are not normally returned'
  },
  {
    user => 'unprivileged',
    args => {match => [$disabled_match], include_disabled => 1},
    test => 'Specifying include_disabled returns disabled users'
  },
  {
    user => 'unprivileged',
    args => {match => [$disabled]},
    test => 'Full match on a disabled user returns that user',
  },

  # groups and group_ids
  {
    args  => {groups => ['QA-Selenium-TEST']},
    test  => 'Specifying just groups fails',
    error => 'one of the following parameters',
  },
  {
    args  => {group_ids => [1]},
    test  => 'Specifying just group ids fails',
    error => 'one of the following parameters',
  },
  {
    args  => {names => [$get_user, $priv_user], groups => ['QA-Selenium-TEST']},
    test  => 'Limiting the return value to a group while being logged out fails',
    error => 'The group you specified, QA-Selenium-TEST, is not valid here',
  },
  {
    user  => 'unprivileged',
    args  => {names => [$get_user, $priv_user], groups => ['missing_group']},
    test  => 'Limiting the return value to a group which does not exist fails',
    error => 'The group you specified, missing_group, is not valid here',
  },
  {
    user  => 'unprivileged',
    args  => {names => [$get_user, $priv_user], groups => ['QA-Selenium-TEST']},
    test  => 'Limiting the return value to a group you do not belong to fails',
    error => 'The group you specified, QA-Selenium-TEST, is not valid here',
  },
  {
    user  => 'editbugs',
    args  => {names => [$get_user, $priv_user], groups => ['Master', 'editbugs']},
    test  => 'Limiting the return value to some groups you do not belong to fails',
    error => 'The group you specified, Master, is not valid here',
  },
  {
    user => 'admin',
    args => {names => [$canconfirm_user], groups => ['canconfirm', 'editbugs']},
    test => 'Limiting the return value to groups you belong to',
  },

  # groups returned
  {user => 'admin',      args => {names => [$get_user]},        test => 'Admin can get user'},
  {user => 'admin',      args => {names => [$canconfirm_user]}, test => 'Admin can get user'},
  {user => 'canconfirm', args => {names => [$canconfirm_user]}, test => 'Privileged user can get themselves'},
  {user => 'editbugs',   args => {names => [$canconfirm_user]}, test => 'Privileged user can get another user'},
);

sub check_success {
  my ($test, $item) = @_;
  my $user = $test->{user} || '';

  if ($user eq 'admin') {
    ok(
      exists $item->{email}
        && exists $item->{can_login}
        && exists $item->{email_enabled}
        && exists $item->{login_denied_text},
      'Admin correctly gets all user fields'
    );
  }
  elsif ($user) {
    ok(exists $item->{email} && exists $item->{can_login},
      'Logged-in user correctly gets email and can_login');
    ok(!exists $item->{email_enabled} && !exists $item->{login_denied_text},
      "Non-admin user doesn't get email_enabled and login_denied_text");
  }
  else {
    my @item_keys = sort keys %$item;
    is_deeply(\@item_keys, ['id', 'name', 'nick', 'real_name'],
      'Only id, name, nick and real_name are returned to logged-out users');
    return;
  }

  my $username = $config->{"${user}_user_login"};

  if ($username eq $item->{name}) {
    ok(exists $item->{saved_searches},
      'Users can get the list of saved searches and reports for their own account');
  }
  else {
    ok(!exists $item->{saved_searches},
      "Users cannot get the list of saved searches and reports from someone else's account");
  }

  my @groups = map { $_->{name} } @{$item->{groups}};
  if ($username eq $item->{name} || $user eq 'admin') {
    if ($username eq $get_user) {
      ok(!scalar @groups, "The unprivileged user doesn't belong to any group");
    }
    elsif ($username eq $canconfirm_user) {
      ok(grep($_ eq 'canconfirm', @groups), "Group 'canconfirm' returned");
    }
  }
  else {
    ok(!scalar @groups, "No groups are visible to users without bless privs");
  }
}

foreach my $test (@tests) {
  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $url_obj = rest_get_url($url, 'rest/user', $test->{args});

  if (my $error = $test->{error}) {
    $t->get_ok($url_obj => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
  }
  else {
    $t->get_ok($url_obj => $headers)->status_is(200);
    my $users = $t->tx->res->json->{users};
    is(scalar @$users, 1, "$test->{test}: got exactly one user");
    check_success($test, $users->[0]);
  }
}

#############################
# Include and Exclude Tests #
#############################

my $anon = api_headers(undef);

$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user], include_fields => ['asdfasdfsdf']}) => $anon)->status_is(200);
is(scalar keys %{$t->tx->res->json->{users}[0]}, 0, 'No fields returned for user');

$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user], include_fields => ['id']}) => $anon)->status_is(200);
is(scalar keys %{$t->tx->res->json->{users}[0]}, 1, 'Only one field returned for user');

$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user], exclude_fields => ['asdfasdfsdf']}) => $anon)->status_is(200);
is(scalar keys %{$t->tx->res->json->{users}[0]}, 4, 'All fields returned for user');

$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user], exclude_fields => ['id']}) => $anon)->status_is(200);
is(scalar keys %{$t->tx->res->json->{users}[0]}, 3, 'Only three fields returned for user');

$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user], include_fields => ['id', 'name'], exclude_fields => ['id']})
  => $anon)->status_is(200);
is(scalar keys %{$t->tx->res->json->{users}[0]}, 1, 'Only one field returned');
ok(exists $t->tx->res->json->{users}[0]{name}, '...and that field is the "name" field');

####################
# Permissive Tests #
####################

# Without permissive, one unknown name fails the whole request.
$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user, 'no-such-user@mozilla.test']}) => $anon)->status_isnt(200);

# With permissive, the unknown name is reported in faults instead.
$t->get_ok(rest_get_url($url, 'rest/user',
  {names => [$get_user, 'no-such-user@mozilla.test'], permissive => 1}) => $anon)
  ->status_is(200)
  ->json_is('/users/0/name'   => $get_user)
  ->json_is('/faults/0/name'  => 'no-such-user@mozilla.test')
  ->json_is('/faults/0/error' => Mojo::JSON->true)
  ->json_like('/faults/0/message' => qr/no-such-user\@mozilla\.test/);
is(scalar @{$t->tx->res->json->{users}},  1, 'permissive: one user returned');
is(scalar @{$t->tx->res->json->{faults}}, 1, 'permissive: one fault returned');

done_testing();
