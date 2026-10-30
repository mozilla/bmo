#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Tests for the REST bug routes not covered by the  #
# per-method tests: Bug.get permissive mode,        #
# GET /rest/bug/, quicksearch, the                  #
# Bug.possible_duplicates param checks, ETag,       #
# needinfo_from matches and OPTIONS                 #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util       qw(get_config);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config  = get_config();
my $url     = Bugzilla->localconfig->urlbase;
my $headers = api_headers($config->{admin_user_api_key});

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# Permissive mode returns the bugs it can, and a fault for each other id.
$t->get_ok($url
    . 'rest/bug/public_bug?ids=99999999&permissive=1&include_fields=id' =>
    $headers)
  ->status_is(200)
  ->json_is('/bugs/0/id'            => 2)
  ->json_is('/faults/0/id'          => 99999999)
  ->json_is('/faults/0/faultCode'   => 101)
  ->json_is('/faults/0/faultString' => 'Bug 99999999 does not exist.');

# Without it, the unknown bug is an error.
$t->get_ok($url . 'rest/bug/99999999' => $headers)->status_is(404)
  ->json_is('/code' => 101);

# GET /rest/bug/ takes the bug ids from the query string.
$t->get_ok($url . 'rest/bug/?ids=public_bug&include_fields=id' => $headers)
  ->status_is(200)
  ->json_is('/bugs/0/id' => 2);

# Quicksearch keeps the other search params, such as limit.
$t->get_ok($url . 'rest/bug?quicksearch=ALL&limit=1&include_fields=id' =>
    $headers)
  ->status_is(200)
  ->json_is('/bugs/0/id' => 1)
  ->json_hasnt('/bugs/1');
$t->get_ok($url . 'rest/bug?quicksearch=public_bug&include_fields=id' =>
    $headers)
  ->status_is(200)
  ->json_is('/bugs/0/id' => 2);

# 'load' asks quicksearch to redirect to the search form; the API ignores it.
$t->get_ok(
  $url . 'rest/bug?quicksearch=ALL&load=1&limit=1&include_fields=id' => $headers)
  ->status_is(200)
  ->json_is('/bugs/0/id' => 1);

# Bug.possible_duplicates rejects unknown params and needs id or summary.
$t->get_ok($url . 'rest/bug/possible_duplicates?summary=bug&foo=1' => $headers)
  ->status_is(400)
  ->json_is('/code' => 53);
$t->get_ok($url
    . 'rest/bug/possible_duplicates?summary=bug&exclude_fields=id' =>
    $headers)
  ->status_is(400)
  ->json_is('/code' => 53);
$t->get_ok($url . 'rest/bug/possible_duplicates' => $headers)->status_is(400)
  ->json_is('/code' => 50);
$t->get_ok($url
    . 'rest/bug/possible_duplicates?summary=testing&include_fields=id' =>
    $headers)
  ->status_is(200)
  ->json_has('/bugs');

# Get, search and history send an ETag, and answer 304 when the client sends
# it back unchanged. The bug get ETag doesn't change with the update tokens.
foreach my $path ('rest/bug/public_bug', 'rest/bug?id=public_bug',
  'rest/bug/public_bug/history')
{
  $t->get_ok($url . $path => $headers)->status_is(200)->header_like(ETag => qr/^"/);
  my $etag = $t->tx->res->headers->etag;
  $t->get_ok($url . $path => {%$headers, 'If-None-Match' => $etag})
    ->status_is(304)->content_is('');
  $t->get_ok($url . $path => {%$headers, 'If-None-Match' => '"stale"'})
    ->status_is(200);
}

# The last_change_time condition doesn't replace the caller's custom search
# conditions, whatever their numbers.
$t->get_ok($url
    . 'rest/bug?f1=bug_id&o1=equals&v1=2'
    . '&last_change_time=1970-01-01T00:00:00Z&include_fields=id' => $headers)
  ->status_is(200)
  ->json_is('/bugs/0/id' => 2);
$t->get_ok($url
    . 'rest/bug?f1=bug_id&o1=equals&v1=2&f3=short_desc&o3=equals&v3=no-such-summary'
    . '&last_change_time=1970-01-01T00:00:00Z&include_fields=id' => $headers)
  ->status_is(200)
  ->json_hasnt('/bugs/0');

# A needinfo_from that matches no one, or several people, is an error: the
# confirmation page of the web UI can't be shown here.
foreach my $from ('no-such-user@example.invalid', 'mozilla.test') {
  $t->put_ok($url . 'rest/bug/public_bug' => $headers => json =>
      {needinfo => 1, needinfo_from => $from, comment => {body => 'needinfo'}})
    ->status_is(400)
    ->json_like('/message' => qr/cannot make a conclusive match/);
}

# OPTIONS lists the methods of each route.
$t->options_ok($url . 'rest/bug')->status_is(200)
  ->header_is(Allow => 'GET, POST');
$t->options_ok($url . 'rest/bug/public_bug')->status_is(200)
  ->header_is(Allow => 'GET, PUT');
$t->options_ok($url . 'rest/bug/public_bug/history')->status_is(200)
  ->header_is(Allow => 'GET');

# /bug/#id doesn't match the deeper routes of the other bug controllers.
$t->options_ok($url . 'rest/bug/comment/render')->status_is(200)
  ->header_is(Allow => 'POST');

done_testing();
