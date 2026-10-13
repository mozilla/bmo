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

use MIME::Base64 qw(encode_base64 decode_base64);
use Mojo::JSON qw(false true);
use Test::Mojo;
use Test::More;

my $config  = get_config();
my $api_key = $config->{admin_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Allow 1 redirect max
$t->ua->max_redirects(1);

### Section 1: Create a new component

my $new_component = {
  name        => 'TestComponent',
  product     => 'Firefox',
  description => 'This is a new test component',
  team_name   => 'Mozilla',
};

# First try unauthenticated. Should fail with error.
$t->post_ok($url . 'rest/component/Firefox' => json => $new_component)
  ->status_is(401)
  ->json_is(
  '/message' => 'You must log in before using this part of Bugzilla.');

# Authenticated but unprivileged. This message is 110 characters long, so an
# exact match also pins that native REST errors are not wrapped at 72 columns.
$t->post_ok($url
    . 'rest/component/Firefox' =>
    {'X-Bugzilla-API-Key' => $config->{unprivileged_user_api_key}} => json =>
    $new_component)->status_is(401)->json_is('/message' =>
  "Sorry, you aren't a member of the 'editcomponents' group, and so you are not authorized to add new components."
  );

# Now try as authenticated user using API key. But a required field is missing (default_assignee).
$t->post_ok($url
    . 'rest/component/Firefox' => {'X-Bugzilla-API-Key' => $api_key} => json =>
    $new_component)->status_is(400)
  ->json_is('/message' => 'A default assignee is required for this component.');

# Now try again with the missing field populated.
$new_component->{default_assignee} = 'admin@mozilla.test';
$t->post_ok($url
    . 'rest/component/Firefox' => {'X-Bugzilla-API-Key' => $api_key} => json =>
    $new_component)->status_is(200)->json_is('/name' => 'TestComponent');

# Retrieve the new component and verify
$t->get_ok($url
    . 'rest/component/Firefox/TestComponent' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/name' => 'TestComponent');

# Adding the same component should generate an error
$t->post_ok($url
    . 'rest/component/Firefox' => {'X-Bugzilla-API-Key' => $api_key} => json =>
    $new_component)->status_is(400)
  ->json_is('/message' =>
    'The Firefox product already has a component named TestComponent.');

# Fields may also be passed entirely via the query string, with no JSON body.
$t->post_ok($url
    . 'rest/component/Firefox?name=QueryStringComponent'
    . '&description=Created%20via%20query%20string'
    . '&default_assignee=admin%40mozilla.test&team_name=Mozilla' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/name' => 'QueryStringComponent');

### Section 2: Make updates to the component

my $update = {
  triage_owner     => 'admin@mozilla.test',
  description      => 'Updated description',
  default_assignee => 'permanent_user@mozilla.test'
};

# Unauthenticated update should fail
$t->put_ok($url . 'rest/component/Firefox/TestComponent' => json => $update)
  ->status_is(401)
  ->json_is(
  '/message' => 'You must log in before using this part of Bugzilla.');

# Authenticated request should work fine.
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent' =>
    {'X-Bugzilla-API-Key' => $api_key}       => json => $update)->status_is(200)
  ->json_is('/triage_owner'     => 'admin@mozilla.test')
  ->json_is('/description'      => 'Updated description')
  ->json_is('/default_assignee' => 'permanent_user@mozilla.test');

# A query-string parameter is also accepted on PUT, and wins over a matching
# parameter in the JSON body.
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent?description=Query%20String%20Wins' =>
    {'X-Bugzilla-API-Key' => $api_key} =>
    json => {description => 'Should Not Be Used'})->status_is(200)
  ->json_is('/description' => 'Query String Wins');

# Retrieve the new component and verify
$t->get_ok($url
    . 'rest/component/Firefox/TestComponent' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/triage_owner' => 'admin@mozilla.test')
  ->json_is('/description'  => 'Query String Wins');

# A form-urlencoded body and the query string may both carry the same field;
# the query string wins and the value stays a plain string (it used to be
# merged into an arrayref and stored as "ARRAY(0x...)").
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent?description=Query%20Beats%20Form' =>
    {'X-Bugzilla-API-Key' => $api_key} =>
    form => {description => 'Form Body Loses'})->status_is(200)
  ->json_is('/description' => 'Query Beats Form');

# A malformed JSON body is rejected instead of being treated as an empty,
# successful update.
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent' =>
    {'X-Bugzilla-API-Key' => $api_key} => '{"description": ')
  ->status_is(400)->json_is('/code' => 32000)
  ->json_like('/message' => qr/JSON data used for the request was malformed/);

# is_active from the query string is the string "true"/"false", which must be
# coerced rather than treated as a truthy string.
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent?is_active=false' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/is_active' => false);
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent?is_active=true' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/is_active' => true);
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent?is_active=maybe' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(400)
  ->json_like('/message' => qr/is_active must be true or false/);

# Update an existing user and give edittriageowners permissions
my $user_update = {groups => {add => ['edittriageowners']}};
$t->put_ok($url
    . 'rest/user/no-privs@mozilla.test' => {'X-Bugzilla-API-Key' => $api_key} =>
    json                                => $user_update)->status_is(200);
my $triage_api_key = $config->{unprivileged_user_api_key};
$update = {triage_owner => 'nobody@mozilla.org'};
$t->put_ok($url
    . 'rest/component/Firefox/TestComponent' =>
    {'X-Bugzilla-API-Key' => $api_key}       => json => $update)->status_is(200)
  ->json_is('/triage_owner' => 'nobody@mozilla.org');

### Section 1: Create a new component with a slash (/) in the name

$new_component = {
  name        => 'Test / Component',
  product     => 'Firefox',
  description => 'This is a new test component with slash',
  team_name   => 'Mozilla',
  default_assignee => 'admin@mozilla.test'
};

$t->post_ok($url
    . 'rest/component/Firefox' => {'X-Bugzilla-API-Key' => $api_key} => json =>
    $new_component)->status_is(200)->json_is('/name' => 'Test / Component');

# Retrieve the new component and verify
$t->get_ok($url
    . 'rest/component/Firefox/Test / Component' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/name' => 'Test / Component');

# Retrieve the component using named query parameters
$t->get_ok($url
    . 'rest/component?product=Firefox&component=Test / Component' =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/name' => 'Test / Component');

# Clean up: revoke the edittriageowners membership granted above so later
# tests (e.g. rest_user_get.t) still see this user as belonging to no groups.
$t->put_ok($url
    . 'rest/user/no-privs@mozilla.test' => {'X-Bugzilla-API-Key' => $api_key}
    => json => {groups => {remove => ['edittriageowners']}})->status_is(200);

done_testing();
