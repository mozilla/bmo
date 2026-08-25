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
use Bugzilla::Attachment;
use Bugzilla::Logging;

use MIME::Base64 qw(decode_base64);
use Mojo::JSON 'true';
use QA::Util qw(get_config generate_payload_signature);
use Test::Mojo;
use Test::More;
use Time::HiRes qw(usleep);

{
  no warnings 'redefine';
  my $original_create = \&Bugzilla::Attachment::create;
  *Bugzilla::Attachment::create = sub {
    my ($invocant, $params) = @_;
    my $delay_us = int($ENV{BMO_GITHUB_PR_TEST_CREATE_DELAY_US} // 0);
    if ($delay_us > 0
      && ref $params eq 'HASH'
      && ($params->{mimetype} // '') eq 'text/x-github-pull-request')
    {
      usleep($delay_us);
    }
    return $original_create->(@_);
  };
}

my $config  = get_config();
my $api_key = $config->{admin_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;
my $secret  = $config->{github_automation_user_api_key};

my $t = Test::Mojo->new();

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

# Verify the bug still has exactly one active attachment for this PR URL.
$t->get_ok(
  $url . "rest/bug/$bug_id/attachment" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200);

my $bug_attachments = $t->tx->res->json->{bugs}->{$bug_id} // [];
my @matching_pr_attachments
  = grep { ($_->{content_type} // '') eq 'text/x-github-pull-request' }
  @$bug_attachments;
is(scalar @matching_pr_attachments, 1,
  'Repeated delivery keeps only one PR attachment on the bug');

# Create another bug and deterministically overlap two identical webhook
# deliveries. The monkeypatch above delays attachment create so both deliveries
# are in-flight at the same time in unlocked implementations.
$t->post_ok(
  $url . 'rest/bug' => {'X-Bugzilla-API-Key' => $api_key} => json => $new_bug)
  ->status_is(200)->json_has('/id');

my $race_bug_id = $t->tx->res->json->{id};
my $race_payload = {
  action       => 'opened',
  pull_request => {
    html_url => 'https://github.com/mozilla-bteam/bmo/pull/2',
    title    => "Bug $race_bug_id - Test GitHub PR Linking",
    number   => 2,
  },
  repository => {full_name => 'foo/bar'}
};

my @child_pids;
my %child_exit_counts;
local $ENV{BMO_GITHUB_PR_TEST_CREATE_DELAY_US} = 500_000;

foreach my $i (1 .. 2) {
  my $pid = fork();
  die "Unable to fork for race test" unless defined $pid;

  if ($pid == 0) {
    my $child_t = Test::Mojo->new();
    my $tx = $child_t->ua->post(
      $url
        . 'rest/github/pull_request' => {
        'X-Hub-Signature-256' => generate_payload_signature($secret, $race_payload),
        'X-GitHub-Event'      => 'pull_request'
        } => json => $race_payload
    );

    my $res = $tx->result;
    exit 2 unless $res && $res->is_success;

    my $json = $res->json // {};
    my $error = defined $json->{error} ? $json->{error} : 99;
    exit($error == 0 ? 0 : ($error == 1 ? 1 : 3));
  }

  push @child_pids, $pid;
}

foreach my $pid (@child_pids) {
  waitpid($pid, 0);
  my $exit_code = $? >> 8;
  $child_exit_counts{$exit_code}++;
}

is($child_exit_counts{0} // 0, 1,
  'One overlapping delivery creates the GitHub PR attachment');
is($child_exit_counts{1} // 0, 1,
  'Second overlapping delivery is rejected as duplicate');

$t->get_ok(
  $url . "rest/bug/$race_bug_id/attachment" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200);

my $race_bug_attachments = $t->tx->res->json->{bugs}->{$race_bug_id} // [];
my @race_pr_attachments
  = grep { ($_->{content_type} // '') eq 'text/x-github-pull-request' }
  @$race_bug_attachments;
is(scalar @race_pr_attachments, 1,
  'Overlapping deliveries commit exactly one PR attachment');

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
