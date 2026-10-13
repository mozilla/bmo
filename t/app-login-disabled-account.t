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
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;
use Bugzilla::Test::Util qw(create_user issue_api_key);

use Bugzilla::Constants;
use Test2::V0;
use Test::Mojo;

# An API key minted while the account was usable must stop working on the
# native Mojo routes as soon as the account is disabled or is confined to a
# password reset, the same way it stops working on rest.cgi and in the web UI.
# Only the native routes are exercised here: the legacy rest.cgi error path
# exits the process, which Test::Mojo cannot survive in-process.

my $disabled = create_user('disabled@mozilla.org', '*');
my $pwreset  = create_user('pwreset@mozilla.org',  '*');
my $enabled  = create_user('enabled@mozilla.org',  '*');

my $disabled_key = issue_api_key('disabled@mozilla.org')->api_key;
my $pwreset_key  = issue_api_key('pwreset@mozilla.org')->api_key;
my $enabled_key  = issue_api_key('enabled@mozilla.org')->api_key;

my $t = Test::Mojo->new('Bugzilla::App');

# Baseline: all three keys work while the accounts are in good standing.
foreach my $key ($disabled_key, $pwreset_key, $enabled_key) {
  $t->get_ok('/rest/webhooks/list' => {'X-Bugzilla-API-Key' => $key})
    ->status_is(200);
}

Bugzilla->set_user(Bugzilla::User->super_user);
$disabled->set_disabledtext('Contract ended. Access revoked.');
$disabled->update();
$pwreset->set_password_change_required(1);
$pwreset->set_password_change_reason('Breach credential match');
$pwreset->update();
Bugzilla->set_user(Bugzilla::User->new);

# The disabled account's key is refused, with the same error the legacy stack
# returns (account_disabled, internal code 301, HTTP 401).
$t->get_ok('/rest/webhooks/list' => {'X-Bugzilla-API-Key' => $disabled_key})
  ->status_is(401)
  ->json_is('/code' => 301);

# So is the key of an account that is only required to change its password.
$t->get_ok('/rest/webhooks/list' => {'X-Bugzilla-API-Key' => $pwreset_key})
  ->status_is(401)
  ->json_is('/code' => 301);

# An untouched account is unaffected.
$t->get_ok('/rest/webhooks/list' => {'X-Bugzilla-API-Key' => $enabled_key})
  ->status_is(200);

# /rest/bug/<id>/graph authenticates while still in USAGE_MODE_REST, because it
# only switches to USAGE_MODE_MOJO_REST after calling login. The refusal has to
# render through the Mojo error plugin anyway; the legacy REST error path would
# die on an unset Bugzilla->_json_server and return a 500 instead.
$t->get_ok('/rest/bug/1/graph' => {'X-Bugzilla-API-Key' => $disabled_key})
  ->status_is(401)
  ->json_is('/code' => 301);

$t->get_ok('/rest/bug/1/graph' => {'X-Bugzilla-API-Key' => $pwreset_key})
  ->status_is(401)
  ->json_is('/code' => 301);

# The same route does not refuse a usable account. Bug 1 may not exist in the
# test database, so only assert that whatever comes back is not account_disabled.
$t->get_ok('/rest/bug/1/graph' => {'X-Bugzilla-API-Key' => $enabled_key})
  ->status_isnt(401);

# Bearer tokens go through bugzilla.oauth rather than the api-key branch above.
# Stub out the OAuth2 plugin's token verification so the account-state policy is
# what is under test here, not the authorization-code exchange.
my $oauth_user_id;
$t->app->helper('oauth' => sub { return {user_id => $oauth_user_id} });

# A disabled account used to be downgraded to an anonymous request here, which
# surfaced as login_required instead of account_disabled.
$oauth_user_id = $disabled->id;
$t->get_ok('/rest/user_profile' => {Authorization => 'Bearer stub'})
  ->status_is(401)
  ->json_is('/code' => 301);

# bugzilla.oauth did not consider password_change_required at all, so such an
# account remained authorized on every bearer-token route.
$oauth_user_id = $pwreset->id;
$t->get_ok('/rest/user_profile' => {Authorization => 'Bearer stub'})
  ->status_is(401)
  ->json_is('/code' => 301);

$oauth_user_id = $enabled->id;
$t->get_ok('/rest/user_profile' => {Authorization => 'Bearer stub'})
  ->status_is(200)
  ->json_is('/login' => $enabled->login);

done_testing;
