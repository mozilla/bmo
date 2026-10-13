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
use QA::Util qw(get_config);

use Test::Mojo;
use Test::More;

my $config  = get_config();
my $api_key = $config->{editbugs_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Allow 1 redirect max
$t->ua->max_redirects(1);

### Section 1: Create a new reminder

my $new_bug = {
  product     => 'Firefox',
  component   => 'General',
  summary     => 'This is a new test bug',
  type        => 'defect',
  version     => 'unspecified',
  severity    => 'blocker',
  description => 'This is a new test bug',
};

$t->post_ok(
  $url . 'rest/bug' => {'X-Bugzilla-API-Key' => $api_key} => json => $new_bug)
  ->status_is(200)->json_has('/id');

my $bug_id = $t->tx->res->json->{id};

my $new_reminder
  = {bug_id => $bug_id, note => 'Test Reminder', reminder_ts => '2024-06-08',};

# First try unauthenticated. Should fail with error.
$t->post_ok($url . 'rest/reminder' => json => $new_reminder)->status_is(401)
  ->json_is(
  '/message' => 'You must log in before using this part of Bugzilla.');

# Now try as authenticated user using API key.
$t->post_ok($url
    . 'rest/reminder' => {'X-Bugzilla-API-Key' => $api_key} => json =>
    $new_reminder)->status_is(200)->json_is('/note' => 'Test Reminder');

my $id = $t->tx->res->json->{id};

### Section 2: View the reminder in list and single

$t->get_ok($url . 'rest/reminder' => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/reminders/0/note' => 'Test Reminder');

$t->get_ok($url . "rest/reminder/$id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/note' => 'Test Reminder');

### Section 3: Remove the reminder

# Passing an invalid value for id should fail
$t->delete_ok($url . "rest/reminder/invalid" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(400)->json_like('/message' => qr/id must be an integer/);

$t->delete_ok($url . "rest/reminder/$id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/success' => 1);

### Section 3b: Fields may also be passed entirely via the query string,
### with no JSON body

$t->post_ok($url
    . "rest/reminder?bug_id=$bug_id&note=Query%20String%20Reminder"
    . '&reminder_ts=2024-06-08' => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/note' => 'Query String Reminder');

my $qs_id = $t->tx->res->json->{id};

$t->delete_ok(
  $url . "rest/reminder/$qs_id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/success' => 1);

### Section 3b-bis: A form-urlencoded body is accepted, not treated as JSON

$t->post_ok($url
    . 'rest/reminder' => {'X-Bugzilla-API-Key' => $api_key} => form =>
    {bug_id => $bug_id, note => 'Form Reminder', reminder_ts => '2024-06-08'})
  ->status_is(200)->json_is('/note' => 'Form Reminder');

my $form_id = $t->tx->res->json->{id};

$t->delete_ok(
  $url . "rest/reminder/$form_id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/success' => 1);

### Section 3c: A malformed JSON body is rejected

$t->post_ok($url
    . 'rest/reminder' => {'X-Bugzilla-API-Key' => $api_key} => '{"bug_id": ')
  ->status_is(400)->json_is('/code' => 32000)
  ->json_like('/message' => qr/JSON data used for the request was malformed/);

### Section 4: Another user cannot delete someone else's reminder

# Create a new reminder as userA (editbugs_user)
$new_reminder
  = {bug_id => $bug_id, note => 'Test Reminder for Editbugs User', reminder_ts => '2024-06-08',};

$t->post_ok($url
    . 'rest/reminder' => {'X-Bugzilla-API-Key' => $api_key} => json =>
    $new_reminder)->status_is(200)->json_is('/note' => 'Test Reminder for Editbugs User');

$id = $t->tx->res->json->{id};

# Try to delete userA's reminder as userB. Should fail with success => 0.
my $other_api_key = $config->{QA_Selenium_TEST_user_api_key};

$t->delete_ok(
  $url . "rest/reminder/$id" => {'X-Bugzilla-API-Key' => $other_api_key})
  ->status_is(200)->json_is('/success' => 0);

# Clean up: verify reminder still exists and delete it as userA
$t->delete_ok(
  $url . "rest/reminder/$id" => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/success' => 1);

done_testing();
