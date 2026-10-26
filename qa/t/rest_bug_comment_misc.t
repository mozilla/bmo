#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Tests for the comment endpoints not covered by    #
# rest_bug_comments.t / rest_bug_add_comment.t:     #
# POST /rest/bug/comment/render                      #
# GET  /rest/bug/comment/tags/<query>                #
# query parameters and OPTIONS                       #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util       qw(get_config random_string);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config  = get_config();
my $url     = Bugzilla->localconfig->urlbase;
my $headers = api_headers($config->{admin_user_api_key});

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# Two comments to work with.
my @comment_ids;
foreach my $text ('first misc comment', 'second misc comment') {
  $t->post_ok(
    $url . 'rest/bug/public_bug/comment' => $headers => json => {comment => $text})
    ->status_is(201);
  push @comment_ids, $t->tx->res->json->{id};
}
my ($first, $second) = @comment_ids;

# A comment id in the path is combined with comment_ids from the query string.
$t->get_ok($url . "rest/bug/comment/$first?comment_ids=$second" => $headers)
  ->status_is(200)
  ->json_is("/comments/$first/text"  => 'first misc comment')
  ->json_is("/comments/$second/text" => 'second misc comment');

# new_since filters out older comments.
$t->get_ok(
  $url . 'rest/bug/public_bug/comment?new_since=2999-01-01' => $headers)
  ->status_is(200);
my ($bug_id) = keys %{$t->tx->res->json->{bugs}};
is_deeply($t->tx->res->json->{bugs}{$bug_id}{comments},
  [], 'No comment is newer than new_since');

# A bug id is a single value: a hash of object conditions is rejected.
$t->post_ok($url
    . 'rest/bug/public_bug/comment' => $headers => json =>
    {id => {condition => 'bug_id = ?', values => [$bug_id]}, comment => 'x'})
  ->status_is(400)
  ->json_is('/error' => 1)
  ->json_like('/message' => qr/id must be a single value/);

# render_comment
$t->post_ok(
  $url . 'rest/bug/comment/render' => $headers => json => {text => 'hello world'})
  ->status_is(200)
  ->json_like('/html' => qr/hello world/);
$t->post_ok($url . 'rest/bug/comment/render' => $headers => json => {})
  ->status_isnt(200)
  ->json_like('/message' => qr/text/);

# Extensions hook into render_comment: the Needinfo extension lists who the
# comment's @mentions would CC and needinfo, only when asked for a given bug.
$t->post_ok($url
    . 'rest/bug/comment/render' => $headers => json =>
    {text => '@nobody-has-this-nick', id => $bug_id, include_mentions => 1})
  ->status_is(200);
$t->json_is('/mentions' => [], 'mentions returned through the hook');
$t->post_ok($url
    . 'rest/bug/comment/render' => $headers => json =>
    {text => '@nobody-has-this-nick', id => $bug_id})->status_is(200);
$t->json_hasnt('/mentions', 'no mentions unless include_mentions is set');

# search_comment_tags finds a tag added through update_comment_tags.
my $tag = 'misc' . lc random_string(8);
$t->put_ok(
  $url . "rest/bug/comment/$first/tags" => $headers => json => {add => [$tag]})
  ->status_is(200)
  ->json_is('' => [$tag]);
# A single value in the query string is still a list.
my $query_tag = 'misc' . lc random_string(8);
$t->put_ok($url . "rest/bug/comment/$first/tags?add=$query_tag" => $headers)
  ->status_is(200);
ok((grep { $_ eq $query_tag } @{$t->tx->res->json}),
  'add from the query string is applied');

$t->get_ok($url . 'rest/bug/comment/tags/' . substr($tag, 0, 8) => $headers)
  ->status_is(200);
ok((grep { $_ eq $tag } @{$t->tx->res->json}), "search finds $tag");
$t->get_ok($url . "rest/bug/comment/tags/$tag" => api_headers(undef))
  ->status_isnt(200)
  ->json_like('/message' => qr/You must log in/);

# OPTIONS
my %allow = (
  'rest/bug/public_bug/comment'       => 'GET, POST',
  "rest/bug/comment/$first"           => 'GET',
  "rest/bug/comment/$first/reactions" => 'GET, PUT',
  "rest/bug/comment/$first/tags"      => 'PUT',
  'rest/bug/comment/render'           => 'POST',
);

foreach my $path (sort keys %allow) {
  $t->options_ok($url . $path)
    ->status_is(200)
    ->header_is('Allow' => $allow{$path});
}

done_testing();
