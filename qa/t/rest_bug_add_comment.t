#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.add_comment()           #
# POST /rest/bug/<id>/comment                         #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

use constant INVALID_BUG_ID    => -1;
use constant INVALID_BUG_ALIAS => 'aaaaaaa12345';

use constant TEST_COMMENT     => '--- Test Comment From QA Tests ---';
use constant TOO_LONG_COMMENT => 'a' x 100000;

my @tests = (

  # Permissions
  {
    args  => {id => 'public_bug', comment => TEST_COMMENT},
    error => 'You must log in',
    test  => 'Logged-out user cannot comment on a public bug',
  },
  {
    args  => {id => 'private_bug', comment => TEST_COMMENT},
    error => "You must log in",
    test  => 'Logged-out user cannot comment on a private bug',
  },
  {
    user  => 'unprivileged',
    args  => {id => 'private_bug', comment => TEST_COMMENT},
    error => "not authorized to access",
    test  => "Unprivileged user can't comment on a private bug",
  },

  # Test ID parameter
  {
    user  => 'unprivileged',
    args  => {id => INVALID_BUG_ID, comment => TEST_COMMENT},
    error => "It does not seem like bug number",
    test  => 'Passing invalid bug id returns error "Invalid Bug ID"',
  },
  {
    user  => 'unprivileged',
    args  => {id => INVALID_BUG_ALIAS, comment => TEST_COMMENT},
    error => "nor an alias to a bug",
    test  => 'Passing invalid bug alias returns error "Invalid Bug Alias"',
  },

  # Test Comment parameter
  {
    user  => 'unprivileged',
    args  => {id => 'public_bug'},
    error => 'a comment argument',
    test  => 'Failing to pass the "comment" parameter fails',
  },
  {
    user  => 'unprivileged',
    args  => {id => 'public_bug', comment => ''},
    error => "a comment argument",
    test  => 'Passing an empty comment fails',
  },
  {
    user  => 'unprivileged',
    args  => {id => 'public_bug', comment => ' '},
    error => 'a comment argument',
    test  => 'Passing only a space for comment fails',
  },
  {
    user  => 'unprivileged',
    args  => {id => 'public_bug', comment => " \t\n\n\r\n\r\n\r "},
    error => 'a comment argument',
    test  => 'Passing only whitespace (including newlines) fails',
  },
  {
    user  => 'unprivileged',
    args  => {id => 'public_bug', comment => TOO_LONG_COMMENT},
    error => "cannot be longer than",
    test  => "Passing a comment that's too long fails",
  },

  # Test work_time parameter
  {
    user  => 'admin',
    args  => {id => 'public_bug', comment => TEST_COMMENT, work_time => 'aaa'},
    error => "is not a numeric value",
    test  => "Passing a non-numeric work_time fails",
  },
  {
    user => 'admin',
    args =>
      {id => 'public_bug', comment => TEST_COMMENT, work_time => '1234567890'},
    error => 'more than the maximum',
    test  => 'Passing too large of a work_time fails',
  },
  {
    user  => 'admin',
    args  => {id => 'public_bug', comment => '', work_time => '1.0'},
    error => 'a comment argument',
    test  => 'Passing a work_time with an empty comment fails',
  },

  # Success tests
  {
    user => 'unprivileged',
    args => {id => 'public_bug', comment => TEST_COMMENT},
    test => 'Unprivileged user can add a comment to a public bug',
  },
  {
    user => 'unprivileged',
    args => {id => 'public_bug', comment => " \n" . TEST_COMMENT},
    test => 'Can add a comment to a bug where the first line is whitespace',
  },
  {
    user          => 'QA_Selenium_TEST',
    args          => {id => 'private_bug', comment => TEST_COMMENT},
    test          => 'Privileged user can add a comment to a private bug',
    check_privacy => 1,
  },
  {
    user          => 'QA_Selenium_TEST',
    args          => {id => 'public_bug', comment => TEST_COMMENT, is_private => 1},
    test          => 'Insidergroup user can add a private comment',
    check_privacy => 1,
  },
  {
    user => 'admin',
    args => {id => 'public_bug', comment => TEST_COMMENT, work_time => '1.5'},
    test => 'Timetracking user can add work_time to a bug',
  },
);

foreach my $test (@tests) {
  my %args = %{$test->{args}};
  my $id   = delete $args{id};

  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $path    = $url . "rest/bug/$id/comment";

  if (my $error = $test->{error}) {
    $t->post_ok($path => $headers => json => \%args)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
    next;
  }

  $t->post_ok($path => $headers => json => \%args)->status_is(201);

  my $comment_id = $t->tx->res->json->{id};

  {
    $t->get_ok($path => $headers)->status_is(200);
    my ($bug) = values %{$t->tx->res->json->{bugs}};
    is($comment_id, $bug->{comments}[-1]{id},
      "$test->{test}: returned id is the new comment's id");
  }

  next unless $test->{check_privacy};

  $t->get_ok($url . "rest/bug/comment/$comment_id" => $headers)->status_is(200);
  my $comment = $t->tx->res->json->{comments}->{$comment_id};
  if ($test->{args}{is_private}) {
    ok($comment->{is_private}, "Comment $comment_id is private");
  }
  else {
    ok(!$comment->{is_private}, "Comment $comment_id is NOT private");
  }
}

done_testing();
