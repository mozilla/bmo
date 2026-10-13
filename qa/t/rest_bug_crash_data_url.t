#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# REST validation and bug-page rendering for cf_crash_data_url.

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config);
use QA::Tests qw(create_bug_fields);
use QA::REST::Util qw(api_headers);

use Mojo::URL;
use Test::Mojo;
use Test::More;

use constant SIGNATURE => '[@ OOM | small]';
use constant CRASH_URL =>
  'https://crash-stats.mozilla.org/search/?signature=%3DOOM%20%7C%20small&platform=Linux';

# Regression case: is_safe_url() rejects URLs ending in ")".
use constant PAREN_URL =>
  'https://crash-stats.mozilla.org/search/?moz_crash_reason=~MOZ_CRASH()';

my $config  = get_config();
my $api_key = $config->{editbugs_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Firefox exposes both crash fields.
sub new_crash_bug {
  my (%fields) = @_;
  my $bug = create_bug_fields($config);
  $bug->{product}          = 'Firefox';
  $bug->{component}        = 'General';
  $bug->{version}          = 'unspecified';
  $bug->{target_milestone} = '---';
  return {%$bug, %fields};
}

sub check_crash_fields {
  my ($bug_id, $signature, $crash_url, $desc) = @_;
  $t->get_ok($url
      . "rest/bug/$bug_id?include_fields=cf_crash_signature,cf_crash_data_url" =>
      api_headers($api_key))->status_is(200)
    ->json_is('/bugs/0/cf_crash_signature', $signature,
    "$desc: signature has the right value")
    ->json_is('/bugs/0/cf_crash_data_url', $crash_url,
    "$desc: crash data url has the right value");
}

sub update_is_rejected {
  my ($bug_id, $fields, $message, $desc) = @_;
  $t->put_ok($url . "rest/bug/$bug_id" => api_headers($api_key) => json => $fields)
    ->status_is(400)->json_is('/code' => 112)
    ->json_like('/message' => $message, "$desc is rejected");
}

my $invalid_url = qr/is not a valid Crash Data URL/;
my $no_signature
  = qr/A Crash Data URL can only be set on a bug with a crash signature/;

# Creation.

$t->post_ok($url
    . 'rest/bug' => api_headers($api_key) => json =>
    new_crash_bug(cf_crash_signature => SIGNATURE, cf_crash_data_url => CRASH_URL))
  ->status_is(200)->json_has('/id');
my $bug_id = $t->tx->res->json->{id};

check_crash_fields($bug_id, SIGNATURE, CRASH_URL, 'After create');

$t->post_ok($url
    . 'rest/bug' => api_headers($api_key) => json =>
    new_crash_bug(cf_crash_data_url => CRASH_URL))->status_is(400)
  ->json_is('/code' => 112)
  ->json_like('/message' => $no_signature,
  'A crash data url without a signature is rejected on create');

$t->post_ok($url
    . 'rest/bug' => api_headers($api_key) => json => new_crash_bug(
    cf_crash_signature => SIGNATURE,
    cf_crash_data_url  => 'https://example.com/search/?platform=Linux'
    )
)->status_is(400)->json_is('/code' => 112)
  ->json_like('/message' => $invalid_url,
  'A non Socorro search url is rejected on create');

# URL validation and trimming.

foreach my $bad_url (
  'http://crash-stats.mozilla.org/search/?platform=Linux',
  'https://crash-stats.mozilla.org/signature/?signature=foo',
  'javascript:alert(1)',
  )
{
  update_is_rejected($bug_id, {cf_crash_data_url => $bad_url},
    $invalid_url, $bad_url);
}

check_crash_fields($bug_id, SIGNATURE, CRASH_URL, 'After rejected urls');

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {cf_crash_data_url => '  ' . PAREN_URL . '  '})->status_is(200);

check_crash_fields($bug_id, SIGNATURE, PAREN_URL, 'After update (trimmed)');

# URL rendering for the table and graph.

$t->get_ok($url . "show_bug.cgi?id=$bug_id")->status_is(200)
  ->attr_is('#field-value-cf_crash_data_url [data-crash-data-url]',
  'data-crash-data-url', PAREN_URL, 'The crash table gets the crash data url')
  ->attr_is('#field-value-cf_crash_data_url a', 'href', PAREN_URL,
  'The crash data url is a link, even when ending with ")"');

my $graph_src = $t->tx->res->dom->at('#chart')->attr('src');
is(Mojo::URL->new($graph_src)->query->param('url'),
  PAREN_URL, 'The crash graph gets the crash data url');

# Require a signature when the URL is set.

update_is_rejected($bug_id, {cf_crash_signature => ''},
  $no_signature, 'Removing the signature but not the crash data url');

check_crash_fields($bug_id, SIGNATURE, PAREN_URL, 'After rejected update');

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {cf_crash_signature => '', cf_crash_data_url => ''})->status_is(200);

check_crash_fields($bug_id, '', '', 'After removing both');

update_is_rejected($bug_id, {cf_crash_data_url => CRASH_URL},
  $no_signature, 'Setting a crash data url without a signature');

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {cf_crash_signature => SIGNATURE, cf_crash_data_url => CRASH_URL})
  ->status_is(200);

check_crash_fields($bug_id, SIGNATURE, CRASH_URL, 'After setting both');

# Clearing the URL removes the graph's extra filters.

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {cf_crash_data_url => ''})->status_is(200);

$t->get_ok($url . "show_bug.cgi?id=$bug_id")->status_is(200);
$graph_src = $t->tx->res->dom->at('#chart')->attr('src');
ok(!defined Mojo::URL->new($graph_src)->query->param('url'),
  'The crash graph is not filtered without a crash data url');

done_testing();
