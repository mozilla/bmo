#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#################################################################
# Test that object IDs sent in a PUT body cannot be a           #
# {condition => ..., values => [...]} hash that reaches the SQL #
# query built by Bugzilla::Object::_load_from_db.               #
# PUT /rest/bug/comment/<id>/reactions                          #
# PUT /rest/bug/comment/<id>/tags                               #
# PUT /rest/bug_modal/update_comment_tags/<id>                  #
# PUT /rest/bug/attachment/<id>                                 #
#################################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use MIME::Base64   qw(encode_base64);
use QA::Util       qw(get_config);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

# Webservice error code for ThrowCodeError('param_must_be_numeric'), and the
# generic code returned for the invalid_params error thrown by
# Bugzilla::WebService::Util::validate().
use constant PARAM_MUST_BE_NUMERIC   => 52;
use constant ERROR_UNKNOWN_TRANSIENT => 32000;

my $config = get_config();
my $url    = Bugzilla->localconfig->urlbase;

# The admin is in editbugs, so it passes the comment_taggers_group check and
# can edit attachments. That way the only thing stopping the request is the
# ID check.
my $headers = api_headers($config->{admin_user_api_key});

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

###############################################
# Create a comment and an attachment to target #
###############################################

$t->post_ok($url
    . 'rest/bug/public_bug/comment' => $headers => json =>
    {comment => 'comment targeted by the condition test'})->status_is(201);
my $comment_id = $t->tx->res->json->{id};
ok($comment_id, "Created comment $comment_id");

$t->post_ok(
  $url
    . 'rest/bug/public_bug/attachment' => $headers => json => {
    summary      => 'attachment targeted by the condition test',
    file_name    => 'condition.txt',
    content_type => 'text/plain',
    data         => encode_base64('condition test', ''),
    }
)->status_is(201);
my ($attach_id) = keys %{$t->tx->res->json->{attachments}};
ok($attach_id, "Created attachment $attach_id");

# Each condition matches a real row. Before the fix, these requests would
# load that row and succeed, which shows the caller controls the WHERE clause.
my $comment_condition
  = {condition => 'comment_id = ?', values => [$comment_id]};
my $attach_condition = {condition => 'attach_id = ?', values => [$attach_id]};

my @tests = (
  {
    test => 'Bug.update_comment_reactions rejects a condition comment_id',
    path => "rest/bug/comment/$comment_id/reactions",
    body => {comment_id => $comment_condition, add => ['+1']},
    code => PARAM_MUST_BE_NUMERIC,
  },
  {
    test => 'Bug.update_comment_tags rejects a condition comment_id',
    path => "rest/bug/comment/$comment_id/tags",
    body => {comment_id => $comment_condition, add => ['condition_test']},
    code => PARAM_MUST_BE_NUMERIC,
  },
  {
    test => 'BugModal.update_comment_tags rejects a condition id',
    path => "rest/bug_modal/update_comment_tags/$comment_id",
    body => {id => $comment_condition, add => ['condition_test']},
    code => PARAM_MUST_BE_NUMERIC,
  },

  # validate(@_, 'ids') already rejects references in ids, so these are
  # caught before the numeric check in update_attachment is reached.
  {
    test => 'Bug.update_attachment rejects a condition in ids',
    path => "rest/bug/attachment/$attach_id",
    body => {ids => [$attach_condition], summary => 'changed by condition'},
    code => ERROR_UNKNOWN_TRANSIENT,
  },
  {
    test => 'Bug.update_attachment rejects a condition as ids',
    path => "rest/bug/attachment/$attach_id",
    body => {ids => $attach_condition, summary => 'changed by condition'},
    code => ERROR_UNKNOWN_TRANSIENT,
  },
);

foreach my $test (@tests) {
  $t->put_ok($url . $test->{path} => $headers => json => $test->{body})
    ->status_is(400)
    ->json_is('/error' => 1)
    ->json_is('/code'  => $test->{code}, $test->{test});
}

# The rejected requests must not have changed anything.
$t->get_ok($url . "rest/bug/attachment/$attach_id" => $headers)
  ->status_is(200)
  ->json_is("/attachments/$attach_id/summary" =>
    'attachment targeted by the condition test');

$t->get_ok($url . "rest/bug/comment/$comment_id/reactions" => $headers)
  ->status_is(200)
  ->json_is('/+1' => undef);

###############################################
# Plain numeric IDs in the body still work    #
###############################################

$t->put_ok($url
    . "rest/bug/comment/$comment_id/reactions" => $headers => json =>
    {comment_id => $comment_id, add => ['+1']})->status_is(200);

$t->put_ok($url
    . "rest/bug/attachment/$attach_id" => $headers => json =>
    {ids => [$attach_id], summary => 'changed by numeric id'})->status_is(200);

$t->get_ok($url . "rest/bug/attachment/$attach_id" => $headers)
  ->status_is(200)
  ->json_is("/attachments/$attach_id/summary" => 'changed by numeric id');

done_testing();
