#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#######################################################
# Test for Bugzilla_login/Bugzilla_password, which    #
# resources still on the legacy REST server accept.   #
# GET /rest/version                                   #
# Delete with the last legacy resource.               #
#######################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util       qw(get_config);
use QA::REST::Util qw(rest_get_url);
use Test::Mojo;
use Test::More;

use constant INVALID_EMAIL => '@invalid_user@';

my $config = get_config();
my $url    = Bugzilla->localconfig->urlbase;

my $user  = $config->{unprivileged_user_login};
my $pass  = $config->{unprivileged_user_passwd};
my $error = "The username or password you entered is not valid";

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

$t->get_ok(rest_get_url(
  $url, 'rest/version', {Bugzilla_login => $user, Bugzilla_password => $pass}
))->status_is(200)->json_has('/version');

my @tests = (
  {login => $user, password => '',    test => "Empty password can't log in"},
  {login => '',    password => $pass, test => "Empty login can't log in"},
  {
    login    => INVALID_EMAIL,
    password => $pass,
    test     => "Invalid email can't log in"
  },
  {login => $user, password => '*', test => "Invalid password can't log in"},
  {
    login    => $config->{disabled_user_login},
    password => $config->{disabled_user_passwd},
    error    => "!!This is the text!!",
    test     => "Can't log in with a disabled account",
  },
  {
    login    => $config->{disabled_user_login},
    password => '*',
    test     => "Logging in with invalid password doesn't show disabledtext",
  },
);

foreach my $test (@tests) {
  $t->get_ok(rest_get_url(
    $url, 'rest/version',
    {Bugzilla_login => $test->{login}, Bugzilla_password => $test->{password}}
  ))->status_isnt(200);
  my $expected = $test->{error} // $error;
  like($t->tx->res->json('/message'), qr/\Q$expected\E/, $test->{test});
}

done_testing();
