#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Exercises authentication for native (Mojolicious) REST endpoints, which
# authenticate through the bugzilla.login helper (Bugzilla::App::Plugin::Login)
# rather than the legacy WebService stack. In particular this verifies that,
# in addition to the X-Bugzilla-API-Key header, the helper accepts the web UI's
# login cookie + Bugzilla_api_token parameter (used by Bugzilla.API in
# JavaScript). A login-required endpoint is used purely as a vehicle; its own
# behaviour is not under test.

use strict;
use warnings;
use 5.10.1;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;

use QA::Util qw(get_config);
use Mojo::JSON qw(decode_json);
use Test::Mojo;
use Test::More;

my $config   = get_config();
my $url      = Bugzilla->localconfig->urlbase;
my $api_key  = $config->{admin_user_api_key};
my $login    = $config->{admin_user_login};
my $password = $config->{admin_user_passwd};

# A native Mojo REST endpoint that requires the user to be logged in.
my $endpoint = 'rest/search/needinfo_last_seen?days=30';

my $t = Test::Mojo->new();
$t->ua->max_redirects(3);

#
# 1. Unauthenticated requests are rejected.
#
$t->get_ok($url . $endpoint)->status_is(401);

#
# 2. Authentication via an API key in the X-Bugzilla-API-Key header works.
#
$t->get_ok($url . $endpoint => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_has('/result');

#
# 2a. Deprecated fallback: an API key passed as the ?api_key= query parameter
#     also works (bug 2073282), same as the legacy WebService dispatcher.
#
$t->get_ok($url . $endpoint . '&api_key=' . $api_key)
  ->status_is(200)->json_has('/result');

#
# 2b. The long form ?Bugzilla_api_key= is accepted too (bug 2073282).
#
$t->get_ok($url . $endpoint . '&Bugzilla_api_key=' . $api_key)
  ->status_is(200)->json_has('/result');

#
# 2c. The header takes precedence over the query parameter: a valid header
#     plus a bogus ?api_key= still authenticates. If the query parameter won,
#     the bogus key would be rejected with a 401. This mirrors the header
#     precedence fix_credentials enforces (t/webservice-fix-credentials.t,
#     bug 2035598).
#
$t->get_ok($url
    . $endpoint
    . '&api_key=bogus-key-value' => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_has('/result');

#
# 3. Authentication via the login cookie + Bugzilla_api_token parameter works.
#    This is the mechanism the web UI (Bugzilla.API) uses, and is the path that
#    native Mojo REST endpoints previously rejected with a 401.
#

# Perform a browser login so the user agent's cookie jar holds valid
# Bugzilla_login and Bugzilla_logincookie cookies.

# The first request seeds the Bugzilla_login_request_cookie (anti-CSRF) cookie.
$t->get_ok($url . 'home')->status_is(200);

# The second request now carries that cookie, so the rendered login form
# contains a matching Bugzilla_login_token.
$t->get_ok($url . 'home')->status_is(200);
my $token_input
  = $t->tx->res->dom->at('input[name="Bugzilla_login_token"]');
my $login_token = $token_input ? $token_input->{value} : '';
ok($login_token, 'Obtained a login request token');

# Submit the login form (the /login route maps to index.cgi?GoAheadAndLogIn=1).
$t->post_ok(
  $url . 'login' => form => {
    Bugzilla_login       => $login,
    Bugzilla_password    => $password,
    Bugzilla_login_token => $login_token,
  }
)->status_is(200);

# Fetch a page and read the Bugzilla_api_token from the embedded page config
# (the #bugzilla-global element's data-bugzilla attribute holds JSON).
# get_api_token() only emits a token when a user is logged in, so a non-empty
# value here also confirms the browser login above succeeded.
$t->get_ok($url . 'home')->status_is(200);
my $global = $t->tx->res->dom->at('#bugzilla-global');
my $bugzilla_json = $global ? $global->attr('data-bugzilla') : undef;
my $bugzilla_config = $bugzilla_json ? decode_json($bugzilla_json) : {};
my $api_token = $bugzilla_config->{api_token};
ok($api_token, 'Logged in and obtained a Bugzilla_api_token');

# 3a. Login cookie + a valid Bugzilla_api_token authenticates the request.
$t->get_ok($url . $endpoint . '&Bugzilla_api_token=' . $api_token)
  ->status_is(200)->json_has('/result');

# 3b. The login cookie alone (no api-token) is not sufficient for a REST
#     request; the api-token acts as a required CSRF guard.
$t->get_ok($url . $endpoint)->status_is(401);

# 3c. Supplying an invalid Bugzilla_api_token is rejected as a bad request
#     (auth_invalid_token) rather than silently falling back to anonymous.
$t->get_ok($url . $endpoint . '&Bugzilla_api_token=invalid-token-value')
  ->status_is(400);

# 3d. A valid Bugzilla_api_token WITHOUT the matching login cookie must not
#     authenticate. A leaked/stolen token is useless on its own; it is only
#     honoured alongside the session cookie it belongs to. Use a fresh user
#     agent so no login cookies are sent.
my $t_no_cookie = Test::Mojo->new();
$t_no_cookie->get_ok($url . $endpoint . '&Bugzilla_api_token=' . $api_token)
  ->status_is(400);

done_testing();
