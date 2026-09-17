#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to User.login()/User.logout()  #
# GET /rest/login                                    #
# GET /rest/logout                                   #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config);
use QA::REST::Util qw(rest_get_url);
use Test::Mojo;
use Test::More;

use constant INVALID_EMAIL => '@invalid_user@';

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $user  = $config->{unprivileged_user_login};
my $pass  = $config->{unprivileged_user_passwd};
my $error = "The username or password you entered is not valid";

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# A successful login returns an id and a token.
$t->get_ok(rest_get_url($url, 'rest/login', {login => $user, password => $pass}))
  ->status_is(200)->json_has('/id')->json_has('/token');
my $token = $t->tx->res->json->{token};

# The returned token can be used to log out again.
$t->get_ok(rest_get_url($url, 'rest/logout', {Bugzilla_token => $token}))
  ->status_is(200);

# Authenticating any call via Bugzilla_login/Bugzilla_password works.
$t->get_ok(
  rest_get_url($url, 'rest/version', {Bugzilla_login => $user, Bugzilla_password => $pass}))
  ->status_is(200)->json_has('/version');

my @tests = (
  {args => {login => $user, password => ''},  error => $error, test => "Empty password can't log in"},
  {args => {login => '', password => $pass},  error => $error, test => "Empty login can't log in"},
  {args => {login => $user}, error => "requires a password argument", test => "Undef password can't log in"},
  {args => {password => $pass}, error => "requires a login argument", test => "Undef login can't log in"},
  {args => {login => INVALID_EMAIL, password => $pass}, error => $error, test => "Invalid email can't log in"},
  {args => {login => $user, password => '*'}, error => $error, test => "Invalid password can't log in"},
  {
    args => {
      login    => $config->{disabled_user_login},
      password => $config->{disabled_user_passwd}
    },
    error => "!!This is the text!!",
    test  => "Can't log in with a disabled account",
  },
  {
    args  => {login => $config->{disabled_user_login}, password => '*'},
    error => $error,
    test  => "Logging in with invalid password doesn't show disabledtext",
  },
);

foreach my $test (@tests) {
  my $args = $test->{args};

  $t->get_ok(rest_get_url($url, 'rest/login', $args))->status_isnt(200);
  like($t->tx->res->json->{message}, qr/\Q$test->{error}\E/, "$test->{test}");

  # Authenticating another call with the same (bad) credentials must also fail.
  if (defined $args->{login} && defined $args->{password}) {
    $t->get_ok(rest_get_url($url, 'rest/version',
      {Bugzilla_login => $args->{login}, Bugzilla_password => $args->{password}}))
      ->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$test->{error}\E/,
      "Bugzilla_login: $test->{test}");
  }
}

done_testing();
