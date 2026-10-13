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
use QA::Util  qw(get_config);
use QA::Tests qw(create_bug_fields PRIVATE_BUG_USER);

use Mojo::JSON qw(encode_json);
use Test::Mojo;
use Test::More;

my $config  = get_config();
my $api_key = $config->{editbugs_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

### Setup: create two bugs to record visits against

sub create_bug {
  my ($summary) = @_;
  $t->post_ok($url
      . 'rest/bug' => {'X-Bugzilla-API-Key' => $api_key} => json => {
        product     => 'Firefox',
        component   => 'General',
        summary     => $summary,
        type        => 'defect',
        version     => 'unspecified',
        severity    => 'blocker',
        description => $summary,
      })->status_is(200)->json_has('/id');
  return $t->tx->res->json->{id};
}

my $bug_id_1 = create_bug('bug_user_last_visit test bug 1');
my $bug_id_2 = create_bug('bug_user_last_visit test bug 2');

### Section 1: Anonymous access requires login

$t->get_ok($url . 'rest/bug_user_last_visit')->status_is(401)
  ->json_is(
  '/message' => 'You must log in before using this part of Bugzilla.');

### Section 2: OPTIONS

$t->options_ok($url . 'rest/bug_user_last_visit')->status_is(200)
  ->header_is('Allow' => 'GET, POST');
$t->options_ok($url . "rest/bug_user_last_visit/$bug_id_1")->status_is(200)
  ->header_is('Allow' => 'GET, POST');

### Section 3: POST /rest/bug_user_last_visit/<id> records a visit via the path

$t->post_ok($url
    . "rest/bug_user_last_visit/$bug_id_1" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)
  ->json_is('/0/id' => $bug_id_1)->json_has('/0/last_visit_ts');

like($t->tx->res->json->[0]->{last_visit_ts}, qr/Z$/, 'last_visit_ts ends in Z');

### Section 4: POST /rest/bug_user_last_visit with a JSON ids body records
### visits for multiple bugs at once

$t->post_ok($url
    . 'rest/bug_user_last_visit' => {'X-Bugzilla-API-Key' => $api_key} =>
    json => {ids => [$bug_id_1, $bug_id_2]})->status_is(200);

my @posted_ids = sort { $a <=> $b } map { $_->{id} } @{$t->tx->res->json};
is_deeply(\@posted_ids, [sort { $a <=> $b } ($bug_id_1, $bug_id_2)],
  'both bugs recorded from a JSON body ids array');

### Section 5: a JSON body ids overrides a path id on POST (matches the
### legacy REST layer, where non-GET body/query params are merged in after,
### and so win over, path-derived params)

$t->post_ok($url
    . "rest/bug_user_last_visit/$bug_id_1" =>
    {'X-Bugzilla-API-Key' => $api_key} => json => {ids => [$bug_id_2]})
  ->status_is(200);

my @body_override_ids = map { $_->{id} } @{$t->tx->res->json};
is_deeply(\@body_override_ids, [$bug_id_2],
  'a JSON body ids overrides the path id on POST');

### Section 6: a JSON body with no Content-Type header still works (real
### frontend callers post this way)

my $raw_json = encode_json({ids => [$bug_id_1]});
$t->post_ok($url
    . 'rest/bug_user_last_visit' => {'X-Bugzilla-API-Key' => $api_key} =>
    $raw_json)->status_is(200);

my @no_content_type_ids = map { $_->{id} } @{$t->tx->res->json};
is_deeply(\@no_content_type_ids, [$bug_id_1],
  'a JSON body with no Content-Type header is still parsed');

### Section 7: GET /rest/bug_user_last_visit/<id> -- the path id wins over a
### query-string ids on GET (unchanged from before the POST precedence fix)

$t->get_ok($url
    . "rest/bug_user_last_visit/$bug_id_1?ids=$bug_id_2" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200);

my @get_path_wins_ids = map { $_->{id} } @{$t->tx->res->json};
is_deeply(\@get_path_wins_ids, [$bug_id_1],
  'the path id wins over a query-string ids on GET');

### Section 8: GET /rest/bug_user_last_visit?ids=...&ids=... filters to the
### requested bugs

$t->get_ok($url
    . "rest/bug_user_last_visit?ids=$bug_id_1&ids=$bug_id_2" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200);

my @get_query_ids = sort { $a <=> $b } map { $_->{id} } @{$t->tx->res->json};
is_deeply(\@get_query_ids, [sort { $a <=> $b } ($bug_id_1, $bug_id_2)],
  'query-string ids filters to the requested bugs');

### Section 9: GET /rest/bug_user_last_visit with no ids at all returns
### every visited bug, not an empty list

$t->get_ok($url . 'rest/bug_user_last_visit' => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200);

my @get_all_ids = sort { $a <=> $b } map { $_->{id} } @{$t->tx->res->json};
ok((grep { $_ == $bug_id_1 } @get_all_ids)
    && (grep { $_ == $bug_id_2 } @get_all_ids),
  'GET with no ids returns every visited bug');

### Section 10: a bug in a group the user is not a member of is not
### accessible, and does not leak through the GET filter

# File it as, and restrict it to, a group the editbugs user is not in. Created
# by the private user so that the editbugs user is not its reporter either.
# Same setup as qa/t/rest_relationship_trees.t.
my $private_api_key = $config->{PRIVATE_BUG_USER . '_user_api_key'};

my $private_bug_data = create_bug_fields($config);
delete $private_bug_data->{cc};
$private_bug_data->{summary}     = 'bug_user_last_visit private test bug';
$private_bug_data->{description} = 'bug_user_last_visit private test bug';

$t->post_ok($url
    . 'rest/bug' => {'X-Bugzilla-API-Key' => $private_api_key} => json =>
    $private_bug_data)->status_is(200)->json_has('/id');

my $private_bug_id = $t->tx->res->json->{id};

$t->put_ok($url
    . "rest/bug/$private_bug_id" => {'X-Bugzilla-API-Key' => $private_api_key}
    => json => {groups => {add => ['QA-Selenium-TEST']}})->status_is(200);

$t->post_ok($url
    . "rest/bug_user_last_visit/$private_bug_id" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(401)
  ->json_is('/code' => 102)
  ->json_like('/message' => qr/not authorized to access/);

$t->get_ok($url
    . "rest/bug_user_last_visit?ids=$private_bug_id" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200);
is_deeply($t->tx->res->json, [],
  'a bug the user cannot see is not returned by GET');

### Section 11: anonymous POST requires login (anonymous GET is section 1)

$t->post_ok($url . 'rest/bug_user_last_visit' => json => {ids => [$bug_id_1]})
  ->status_is(401)
  ->json_is(
  '/message' => 'You must log in before using this part of Bugzilla.');

### Section 12: a nonexistent bug id fails the whole request, and the visit
### recorded earlier in the same loop is rolled back

$t->post_ok($url
    . "rest/bug_user_last_visit/$bug_id_1" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200);
my $ts_before = $t->tx->res->json->[0]->{last_visit_ts};

# last_visit_ts has second granularity, so without this the rolled-back and
# the would-be-new timestamp could be identical and the test pass spuriously.
sleep 1;

# Bugzilla::Bug->new sets error => 'InvalidBugId' rather than 'NotFound' when
# handed a hashref, so check() reports improper_bug_id_field_value with no bug
# id rather than bug_id_does_not_exist. The legacy endpoint calls check() the
# same way and behaves identically.
$t->post_ok($url
    . 'rest/bug_user_last_visit' => {'X-Bugzilla-API-Key' => $api_key} =>
    json => {ids => [$bug_id_1, 99999999]})->status_is(400)
  ->json_is('/code' => 100)->json_like('/message' => qr/valid bug number/);

$t->get_ok($url
    . "rest/bug_user_last_visit/$bug_id_1" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200);
is($t->tx->res->json->[0]->{last_visit_ts},
  $ts_before, 'the visit recorded before the bad id was rolled back');

### Section 13: POST with no ids in the path, query string or body

$t->post_ok($url
    . 'rest/bug_user_last_visit' => {'X-Bugzilla-API-Key' => $api_key} =>
    json => {})->status_is(400)->json_is('/code' => 50)
  ->json_like('/message' => qr/argument was not set/);

### Section 14: include_fields / exclude_fields

$t->get_ok($url
    . "rest/bug_user_last_visit/$bug_id_1?include_fields=id" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)->json_has('/0/id')
  ->json_hasnt('/0/last_visit_ts');

$t->get_ok($url
    . "rest/bug_user_last_visit/$bug_id_1?exclude_fields=last_visit_ts" =>
    {'X-Bugzilla-API-Key' => $api_key})->status_is(200)->json_has('/0/id')
  ->json_hasnt('/0/last_visit_ts');

done_testing();
