#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PUT /rest/user/<login> takes login and password as user fields, but a login
# and password sent together are credentials, as on the legacy server: they
# are dropped and change nothing. The password sent is always the account's
# own, so the account keeps it even if that breaks.

use strict;
use warnings;
use 5.10.1;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;

use QA::Util qw(get_config);

use Test::Mojo;
use Test::More;

my $config          = get_config();
my $admin_api_key   = $config->{admin_user_api_key};
my $target_login    = $config->{editusers_target_user_login};
my $target_password = $config->{editusers_target_user_passwd};
my $url             = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

sub update_target {
  my ($params) = @_;
  $t->put_ok($url
      . "rest/user/$target_login" => {'X-Bugzilla-API-Key' => $admin_api_key} =>
      json                        => $params)->status_is(200);
  return $t->tx->res->json->{users}[0]{changes};
}

# Setting the same password still stores a new hash, so it shows as a change.
my $changes = update_target({password => $target_password});
ok(exists $changes->{cryptpassword}, 'password alone is a user field');

$changes
  = update_target({email => $target_login, password => $target_password});
ok(exists $changes->{cryptpassword},
  'password sent with email is a user field');

# An invalid login is refused only if login is kept.
$t->put_ok($url
    . "rest/user/$target_login" => {'X-Bugzilla-API-Key' => $admin_api_key} =>
    json                        => {login => 'not an email address'})
  ->json_is('/error', 1, 'login alone is a user field');

$changes = update_target({
  full_name => 'REST Credentials Target ' . time(),
  login     => $target_login,
  password  => $target_password,
});
ok(exists $changes->{full_name}, 'the other fields are updated');
ok(!exists $changes->{cryptpassword},
  'password sent with login is a credential, not a change');

update_target({full_name => $config->{editusers_target_user_username}});

done_testing();
