#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Util::request(): how Conduit calls are encoded and how transport,
# HTTP and Conduit failures surface to callers.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Config qw(SetParam);
use Test::More;
use Test2::Tools::Exception qw(dies);

use Bugzilla::Extension::PhabBugz::Project;
use Bugzilla::Extension::PhabBugz::Util qw(request);
use PhabTest::Conduit                   qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

# Successful call: URL, token and params encoding
{
  $conduit->reset_calls;
  my $user = $env->phab_bot_phab;
  my $result
    = request('user.search', {constraints => {phids => [$user->{phid}]}});

  ok(!$result->{error_code}, 'successful call has no error_code');
  is($result->{result}{data}[0]{phid}, $user->{phid}, 'result payload returned');

  my ($call) = $conduit->calls;
  is($call->{method}, 'user.search', 'method taken from the URL path');
  is_deeply(
    $call->{params},
    {constraints => {phids => [$user->{phid}]}},
    'params sent as JSON in the `params` form field'
  );

  # The base URI param must end in a slash (check_urlbase) and request()
  # appends "/api/", so the path has a double slash. Phabricator accepts it,
  # but it is not intended; the fake Conduit accepts either form.
  like(
    $call->{url},
    qr{^\Qhttps://phabricator.test.example.com/\E/?api/user\.search$},
    'URL is <phabricator_base_uri>/api/<method>'
  );
TODO: {
    local $TODO = 'request() joins base_uri and "/api/" with a double slash';
    unlike($call->{url}, qr{//api/}, 'URL has a single slash before "api"');
  }

  ok(
    Bugzilla->request_cache->{phabricator_ua},
    'user agent cached in the request cache'
  );
}

# The caller's data hash gets the API token added to it
{
  my $data = {constraints => {phids => []}};
  request('project.search', $data);
  is_deeply(
    $data->{__conduit__},
    {token => $conduit->api_key},
    'request() adds __conduit__ token to the caller data hash'
  );
}

# Missing configuration
{
  SetParam('phabricator_api_key', '');
  $conduit->reset_calls;
  throws_error(
    sub { request('user.search', {}) },
    'bugzilla.user.invalid_phabricator_api_key',
    'missing API key'
  );
  is($conduit->call_count, 0, 'no HTTP request without an API key');
  $conduit->apply_params;

  SetParam('phabricator_base_uri', '');
  throws_error(
    sub { request('user.search', {}) },
    'bugzilla.user.invalid_phabricator_uri',
    'missing base URI'
  );
  is($conduit->call_count, 0, 'no HTTP request without a base URI');
  $conduit->apply_params;

  like(
    dies { SetParam('phabricator_base_uri', 'https://phabricator.example.com') },
    qr/ends with a slash/,
    'base URI param must end with a slash'
  );
  $conduit->apply_params;
}

# HTTP errors always throw, even with $no_die
foreach my $code (400, 403, 404, 500, 502, 503, 504) {
  $conduit->queue('user.search' => http_error($code)) for 1 .. 2;

  my $error = throws_error(
    sub { request('user.search', {}) },
    'bugzilla.code.phabricator_api_error',
    "HTTP $code throws"
  );
  like($error->info->{reason}, qr/\w/, "HTTP $code reason is the status message")
    if $error;

  throws_error(
    sub { request('user.search', {}, 1) },
    'bugzilla.code.phabricator_api_error',
    "HTTP $code throws with no_die"
  );
}

# Body that is not JSON (proxy error page, truncated response)
foreach my $no_die (0, 1) {
  $conduit->queue('user.search' => invalid_json());
  my $error = throws_error(
    sub { request('user.search', {}, $no_die) },
    'bugzilla.code.phabricator_api_error',
    "non-JSON body (no_die=$no_die)"
  );
  is($error->info->{reason}, 'JSON decode failure', 'reason for non-JSON body')
    if $error;
}

$conduit->queue(
  'user.search' => raw_reply('{"result": {"data": [', 'application/json'));
throws_error(
  sub { request('user.search', {}) },
  'bugzilla.code.phabricator_api_error',
  'truncated JSON body'
);

# Conduit-level errors (HTTP 200 with error_code)
{
  $conduit->queue('user.search' =>
      conduit_error('ERR-INVALID-AUTH', 'API token "api-x" has the wrong length.'));
  my $error = throws_error(
    sub { request('user.search', {}) },
    'bugzilla.code.phabricator_api_error',
    'Conduit error_code throws'
  );
  if ($error) {
    is($error->info->{code}, 'ERR-INVALID-AUTH', 'error code passed on');
    like($error->info->{reason}, qr/wrong length/, 'error info passed on');
  }

  $conduit->queue(
    'user.search' => conduit_error('ERR-CONDUIT-CORE', 'Some failure'));
  my $result = request('user.search', {}, 1);
  is($result->{error_code}, 'ERR-CONDUIT-CORE', 'no_die returns the error_code');
  is($result->{error_info}, 'Some failure',     'no_die returns the error_info');

  request('no.such.method', {}, 1);
  is_deeply($conduit->unexpected, ['no.such.method'],
    'unknown method answered with ERR-CONDUIT-CALL');
  @{$conduit->unexpected} = ();
}

# Transport failures: Mojo::UserAgent croaks from $tx->result. request()
# does not catch these, so callers see a plain die, not a Bugzilla error.
foreach my $message (
  'Connection refused',
  'Inactivity timeout',
  "Can't connect: Name or service not known"
  )
{
  $conduit->queue('user.search' => network_error($message));
  like(
    dies { request('user.search', {}) },
    qr/^\Q$message\E/,
    "network failure '$message' propagates"
  );
}

# A 200 response without a `result` key is returned as-is; the model
# classes treat it as "nothing found".
{
  $conduit->queue(
    'project.search' => raw_reply('{"error_code":null,"error_info":null}'));
  my $result = request('project.search', {});
  ok(!defined $result->{result}, 'missing result key does not throw');

  $conduit->queue(
    'project.search' => raw_reply('{"error_code":null,"error_info":null}'));
  ok(
    !Bugzilla::Extension::PhabBugz::Project->new_from_query({name => 'anything'}),
    'Project->new_from_query finds nothing for a missing result');
}

$env->finish;
done_testing;
