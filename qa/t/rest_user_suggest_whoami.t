#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST calls to User.suggest() and whoami  #
# GET /rest/user/suggest                            #
# GET /rest/whoami                                  #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util       qw(get_config);
use QA::REST::Util qw(api_headers rest_get_url);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url    = Bugzilla->localconfig->urlbase;

my $login   = $config->{unprivileged_user_login};
my $headers = api_headers($config->{unprivileged_user_api_key});
my $anon    = api_headers(undef);

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

###########
# suggest #
###########

$t->get_ok($url . 'rest/user/suggest' => $headers)
  ->status_isnt(200)
  ->json_like('/message' => qr/one of the following parameters/);

$t->get_ok(rest_get_url($url, 'rest/user/suggest', {match => $login}) => $anon)
  ->status_isnt(200)
  ->json_like('/message' => qr/Logged-out users cannot use/);

$t->get_ok(rest_get_url($url, 'rest/user/suggest', {match => 'no'}) => $headers)
  ->status_is(200)
  ->json_is('/users' => []);

# Same call as the user autocomplete in js/field.js. "requests" is added by
# the Review extension through the webservice_user_get hook.
$t->get_ok(
  rest_get_url($url, 'rest/user/suggest', {match => $login}) => $headers)
  ->status_is(200)
  ->json_is('/users/0/name' => $login)
  ->json_has('/users/0/id')
  ->json_has('/users/0/real_name')
  ->json_has('/users/0/nick')
  ->json_has('/users/0/requests/review/blocked');

$t->get_ok(
  rest_get_url($url, 'rest/user/suggest',
    {match => $login, include_fields => 'gravatar'}) => $headers
  )
  ->status_is(200)
  ->json_has('/users/0/gravatar')
  ->json_hasnt('/users/0/requests');

##########
# whoami #
##########

$t->get_ok($url . 'rest/whoami' => $anon)->status_is(401);

$t->get_ok($url . 'rest/whoami' => $headers)
  ->status_is(200)
  ->json_is('/name'       => $login)
  ->json_is('/mfa_status' => Mojo::JSON->false)
  ->json_is('/groups'     => [])
  ->json_like('/id'   => qr/^\d+$/)
  ->json_like('/uuid' => qr/^bmo-who:[0-9a-f]{40}$/);

$t->get_ok(
  rest_get_url($url, 'rest/whoami', {include_fields => 'id,name'}) => $headers)
  ->status_is(200);
is_deeply(
  [sort keys %{$t->tx->res->json}],
  ['id', 'name'],
  'whoami honours include_fields'
);

done_testing();
