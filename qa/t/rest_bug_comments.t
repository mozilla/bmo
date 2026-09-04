#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.comments()              #
# GET /rest/bug/<id>/comment                          #
# GET /rest/bug/comment/<comment_id>                  #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use DateTime;
use QA::Util qw(get_config);
use QA::Tests qw(STANDARD_BUG_TESTS PRIVATE_BUG_USER);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

my $creation_time;
my %comments = (
  public_comment_public_bug   => 0,
  public_comment_private_bug  => 0,
  private_comment_public_bug  => 0,
  private_comment_private_bug => 0,
);

sub test_comments {
  my ($comments_returned, $test) = @_;

  my $comment = $comments_returned->[0];
  ok($comment->{bug_id}, "bug_id exists");

  if ($test->{args}->{comment_ids}) {
    my $expected_id = $test->{args}->{comment_ids}->[0];
    is($comment->{id}, $expected_id, "comment id is correct");

    my %reverse_map   = reverse %comments;
    my $expected_text = $reverse_map{$expected_id};
    is($comment->{text}, $expected_text, "comment has the correct text");

    my $priv_login = $config->{PRIVATE_BUG_USER . '_user_login'};
    is($comment->{creator}, $priv_login, "comment creator is correct");

    my $creation_day = $creation_time->ymd;
    like(
      $comment->{time},
      qr/^\Q${creation_day}\ET\d\d:\d\d:\d\d/,
      "comment time has the right format"
    );
  }
  else {
    foreach my $field (qw(id text creator time)) {
      ok(defined $comment->{$field}, "$field is defined");
    }
  }
}

################
# Bug ID Tests #
################

foreach my $test (@{STANDARD_BUG_TESTS()}) {
  my $id = $test->{args}{ids}[0];
  next if !defined $id;

  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $path    = $url . "rest/bug/$id/comment";

  if (my $error = $test->{error}) {
    $t->get_ok($path => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
  }
  else {
    $t->get_ok($path => $headers)->status_is(200);
    my @bugs = values %{$t->tx->res->json->{bugs}};
    is(scalar @bugs, 1, "Got exactly one bug");
    my @returned = map { @{$_->{comments}} } @bugs;
    test_comments(\@returned, $test);
  }
}

####################
# Comment ID Tests #
####################

# First, create comments using add_comment, as PRIVATE_BUG_USER.
$creation_time = DateTime->now();
my $priv_key = $config->{PRIVATE_BUG_USER . '_user_api_key'};

foreach my $key (keys %comments) {
  $key =~ /^([a-z]+)_comment_(\w+)$/;
  my $is_private = ($1 eq 'private' ? 1 : 0);
  my $bug_alias  = $2;
  $t->post_ok($url . "rest/bug/$bug_alias/comment" =>
      {'X-Bugzilla-API-Key' => $priv_key} =>
      json => {comment => $key, is_private => $is_private})->status_is(201);
  $comments{$key} = $t->tx->res->json->{id};
}

# Now check access on each private and public comment

my @comment_tests = (

  # Logged-out user
  {
    args => {comment_ids => [$comments{'public_comment_public_bug'}]},
    test => 'Logged-out user can access public comment on public bug by id',
  },
  {
    args  => {comment_ids => [$comments{'private_comment_public_bug'}]},
    test  => 'Logged-out user cannot access private comment on public bug',
    error => 'is private',
  },
  {
    args  => {comment_ids => [$comments{'public_comment_private_bug'}]},
    test  => 'Logged-out user cannot access comments by id on private bug',
    error => 'You are not authorized to access',
  },
  {
    args  => {comment_ids => [$comments{'private_comment_private_bug'}]},
    test  => 'Logged-out user cannot access private comment on private bug',
    error => 'You are not authorized to access',
  },

  # Logged-in, unprivileged user.
  {
    user => 'unprivileged',
    args => {comment_ids => [$comments{'public_comment_public_bug'}]},
    test => 'Logged-in user can see a public comment on a public bug by id',
  },
  {
    user  => 'unprivileged',
    args  => {comment_ids => [$comments{'private_comment_public_bug'}]},
    test  => 'Logged-in user cannot access private comment on public bug',
    error => 'is private',
  },
  {
    user  => 'unprivileged',
    args  => {comment_ids => [$comments{'public_comment_private_bug'}]},
    test  => 'Logged-in user cannot access comments by id on private bug',
    error => "You are not authorized to access",
  },
  {
    user  => 'unprivileged',
    args  => {comment_ids => [$comments{'private_comment_private_bug'}]},
    test  => 'Logged-in user cannot access private comment on private bug',
    error => "You are not authorized to access",
  },

  # User who can see private bugs and private comments
  {
    user => PRIVATE_BUG_USER,
    args => {comment_ids => [$comments{'private_comment_public_bug'}]},
    test => PRIVATE_BUG_USER . ' can see private comment on public bug',
  },
  {
    user => PRIVATE_BUG_USER,
    args => {comment_ids => [$comments{'private_comment_private_bug'}]},
    test => PRIVATE_BUG_USER . ' can see private comment on private bug',
  },
);

foreach my $test (@comment_tests) {
  my $cid     = $test->{args}{comment_ids}[0];
  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $path    = $url . "rest/bug/comment/$cid";

  if (my $error = $test->{error}) {
    $t->get_ok($path => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
  }
  else {
    $t->get_ok($path => $headers)->status_is(200);
    my @returned = values %{$t->tx->res->json->{comments}};
    is(scalar @returned, 1, "Got exactly one comment");
    test_comments(\@returned, $test);
  }
}

###########################
# Collapsed Comment Tests #
###########################

# Comments tagged with one of the collapsed_comment_tags are collapsed in the
# web UI, so they are left out of the API response unless the caller asks for
# them with include_fields=_collapsed_comments.

my $admin_key = $config->{admin_user_api_key};

$t->post_ok($url
    . 'rest/bug/public_bug/comment' => {'X-Bugzilla-API-Key' => $admin_key} =>
    json => {comment => 'spammy comment'})->status_is(201);
my $spam_id = $t->tx->res->json->{id};

$t->put_ok($url
    . "rest/bug/comment/$spam_id/tags" =>
    {'X-Bugzilla-API-Key' => $admin_key} => json => {add => ['spam']})
  ->status_is(200);

my $bug_comment_path = $url . 'rest/bug/public_bug/comment';

$t->get_ok($bug_comment_path => api_headers($admin_key))->status_is(200);
my @ids = map { $_->{id} } map { @{$_->{comments}} }
  values %{$t->tx->res->json->{bugs}};
ok(!grep({ $_ == $spam_id } @ids), 'collapsed comment is omitted by default');

$t->get_ok($bug_comment_path
    . '?include_fields=_default,_collapsed_comments' => api_headers($admin_key))
  ->status_is(200);
my ($spam_comment)
  = grep { $_->{id} == $spam_id } map { @{$_->{comments}} }
  values %{$t->tx->res->json->{bugs}};
ok($spam_comment, 'collapsed comment is returned with _collapsed_comments');
ok($spam_comment->{collapsed}, 'collapsed comment is flagged as collapsed');

# GET /rest/bug?include_fields=comments is a separate code path (_bug_to_hash).
$t->get_ok($url
    . 'rest/bug/public_bug?include_fields=comments' => api_headers($admin_key))
  ->status_is(200);
@ids = map { $_->{id} } @{$t->tx->res->json->{bugs}->[0]->{comments}};
ok(!grep({ $_ == $spam_id } @ids),
  'collapsed comment is omitted by default from GET /rest/bug');

$t->get_ok($url
    . 'rest/bug/public_bug?include_fields=comments,_collapsed_comments' =>
    api_headers($admin_key))->status_is(200);
@ids = map { $_->{id} } @{$t->tx->res->json->{bugs}->[0]->{comments}};
ok(grep({ $_ == $spam_id } @ids),
  'collapsed comment is returned from GET /rest/bug with _collapsed_comments');

# Requesting the comment by id returns it either way.
$t->get_ok($url . "rest/bug/comment/$spam_id" => api_headers($admin_key))
  ->status_is(200)->json_is("/comments/$spam_id/id", $spam_id,
  'collapsed comment is returned when requested by id');

done_testing();
