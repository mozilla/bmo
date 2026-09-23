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
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Bugzilla::Logging;

use MIME::Base64 qw(decode_base64);
use Mojo::JSON 'true';
use QA::Util qw(get_config generate_payload_signature);
use Test::Mojo;
use Test::More;

my $config  = get_config();
my $api_key = $config->{admin_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;
my $secret  = $config->{github_automation_user_api_key};

my $t = Test::Mojo->new();

# pull_request attributes both the attachment-created comment and the
# moved/obsoleted comment to the webhook bot account whose API key signed the
# request. In this test that is the github-automation account itself.
my $attribution
  = "(via GitHub webhook, authenticated as $config->{github_automation_user_login})";

# Return the text of the most recent comment on a bug.
sub last_comment_text {
  my ($bug_id) = @_;
  $t->get_ok(
    $url . "rest/bug/$bug_id/comment" => {'X-Bugzilla-API-Key' => $api_key})
    ->status_is(200);
  my $comments = $t->tx->res->json->{bugs}->{$bug_id}->{comments};
  return $comments->[-1]->{text};
}

# Create a new test bug for linking to PR
my $new_bug = {
  product     => 'Firefox',
  component   => 'General',
  summary     => 'Test GitHub PR Linking',
  type        => 'defect',
  version     => 'unspecified',
  severity    => 'blocker',
  description => 'This is a new test bug',
};

$t->post_ok(
  $url . 'rest/bug' => {'X-Bugzilla-API-Key' => $api_key} => json => $new_bug)
  ->status_is(200)->json_has('/id');

my $bug_id = $t->tx->res->json->{id};

# Not a pull request event
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, {}),
    'X-GitHub-Event'      => 'foobar'
    } => json => {}
)->status_is(400)
  ->json_like(
  '/message' => qr/The webhook event was not for a GitHub pull request/);

# Mismatching signatures
$t->post_ok($url
    . 'rest/github/pull_request'                                         =>
    {'X-Hub-Signature-256' => 'XXX', 'X-GitHub-Event' => 'pull_request'} =>
    json => {})->status_is(400)
  ->json_like('/message' =>
    qr/The webhook signature in the header did not match the expected value/);

# Invalid JSON
my $payload
  = {pull_request => {html_url => 'https://github.com/mozilla-bteam/bmo/pull/1'}
  };
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'pull_request'
    } => json => $payload
)->status_is(400)
  ->json_like('/message' =>
    qr/The following errors occurred when validating input data/);

# Invalid event type
$payload = {
  action       => 'closed',
  pull_request => {
    html_url => 'https://github.com/mozilla-bteam/bmo/pull/1',
    title    => "Bug $bug_id - Test GitHub PR Linking",
    number   => 1,
  },
  repository => {full_name => 'foo/bar'}
};
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'pull_request'
    } => json => $payload
)->status_is(200)
  ->json_like(
  '/message' => qr/The webhook sent a pull request event that was not an/);

# Invalid Bug ID
$payload = {
  action       => 'opened',
  pull_request => {
    html_url => 'https://github.com/mozilla-bteam/bmo/pull/1',
    title    => 'Bug 1000 - Test GitHub PR Linking',
    number   => 1,
  },
  repository => {full_name => 'foo/bar'}
};
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'pull_request'
    } => json => $payload
)->status_is(200)->json_is('/error', 1)
  ->json_like(
  '/message' => qr/The pull request title did not contain a valid bug ID/);

# https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads
$payload = {
  action       => 'opened',
  pull_request => {
    html_url => 'https://github.com/mozilla-bteam/bmo/pull/1',
    title    => "Bug $bug_id - Test GitHub PR Linking",
    number   => 1
  },
  repository => {full_name => 'foo/bar'}
};

my $good_title
  = '['
  . $payload->{repository}->{full_name} . '] '
  . $payload->{pull_request}->{title} . ' (#'
  . $payload->{pull_request}->{number} . ')';

# Post the valid GitHub event to the rest/github/pull_request API endpoint
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'pull_request'
    } => json => $payload
)->status_is(200)->json_has('/id');

my $attach_id = $t->tx->res->json->{id};

# Retrieve the new attachment from the bug to make sure it was created correctly
$t->get_ok(
  $url . "rest/bug/attachment/$attach_id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is("/attachments/$attach_id/content_type",
  'text/x-github-pull-request')
  ->json_is("/attachments/$attach_id/description", $good_title)
  ->json_is("/attachments/$attach_id/file_name", 'github-foo_bar-1-url.txt');

my $attach_data = $t->tx->res->json->{attachments}->{$attach_id}->{data};
$attach_data = decode_base64($attach_data);
ok($attach_data eq 'https://github.com/mozilla-bteam/bmo/pull/1');

# The attachment-created comment must name the webhook credential so the
# identity behind the github-automation change is visible in bug history.
like(last_comment_text($bug_id), qr/\Q$attribution\E/,
  'attachment-created comment is attributed to the webhook credential');

# Bug already had the same github attachment so don't add twice
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'pull_request'
    } => json => $payload
)->status_is(200)->json_is('/error', 1)
  ->json_like('/message' =>
    qr/The pull request contained a bug ID that already has an attachment/);

# Create a second bug for testing attaching the same github pr but to a
# different bug. For example if someone changes the bug ID in the title
# of an existing pull request. The first attachment should be obsoleted
# after creating the second one.
$t->post_ok(
  $url . 'rest/bug' => {'X-Bugzilla-API-Key' => $api_key} => json => $new_bug)
  ->status_is(200)->json_has('/id');

my $bug_id_2 = $t->tx->res->json->{id};

# Post the valid GitHub event to the rest/github/pull_request API endpoint
$payload->{pull_request}->{title} = "Bug $bug_id_2 - Test GitHub PR Linking";
$good_title = $payload->{pull_request}->{title} . ' (#'
  . $payload->{pull_request}->{number} . ')';
$good_title
  = '['
  . $payload->{repository}->{full_name} . '] '
  . $payload->{pull_request}->{title} . ' (#'
  . $payload->{pull_request}->{number} . ')';

$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'pull_request'
    } => json => $payload
)->status_is(200)->json_has('/id');

my $attach_id_2 = $t->tx->res->json->{id};

# Retrieve the new attachment from the bug to make sure it was created correctly
$t->get_ok(
  $url . "rest/bug/attachment/$attach_id_2" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is("/attachments/$attach_id_2/content_type",
  'text/x-github-pull-request')
  ->json_is("/attachments/$attach_id_2/description", $good_title)
  ->json_is("/attachments/$attach_id_2/file_name", 'github-foo_bar-1-url.txt');

my $attach_data_2 = $t->tx->res->json->{attachments}->{$attach_id_2}->{data};
$attach_data_2 = decode_base64($attach_data_2);
ok($attach_data_2 eq 'https://github.com/mozilla-bteam/bmo/pull/1');

# Retrieve the old attachment from the previous bug and make sure it was obsoleted.
$t->get_ok(
  $url . "rest/bug/attachment/$attach_id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is("/attachments/$attach_id/is_obsolete", true);

# The new bug's attachment comment and the old bug's moved/obsoleted comment
# must both carry the attribution trailer.
like(last_comment_text($bug_id_2), qr/\Q$attribution\E/,
  'attachment-created comment on the second bug is attributed');
like(last_comment_text($bug_id), qr/\Q$attribution\E/,
  'moved/obsoleted attachment comment is attributed');

# Test that ping events (when the webhook is first created) are successful
# a valid signature is also provided
# Post the valid GitHub event to the rest/github/pull_request API endpoint
$payload = {hook => {type => 'Repository'}};
$t->post_ok(
  $url
    . 'rest/github/pull_request' => {
    'X-Hub-Signature-256' => generate_payload_signature($secret, $payload),
    'X-GitHub-Event'      => 'ping'
    } => json => $payload
)->status_is(200)->json_is('/error' => 0);

done_testing();
