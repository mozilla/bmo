#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Verifies that PUT /rest/user/<login_or_id> enforces the same protected
# account rules as editusers.cgi: holding editusers is not enough to modify an
# account which belongs to the admin group, or to the insider group unless the
# caller has insider or servicedesk access.

use strict;
use warnings;
use 5.10.1;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;

use QA::Util qw(get_config);

use Test::Mojo;
use Test::More;

my $config               = get_config();
my $admin_api_key        = $config->{admin_user_api_key};
my $admin_login          = $config->{admin_user_login};
my $admin_realname       = $config->{admin_user_username};
my $unprivileged_api_key = $config->{unprivileged_user_api_key};
my $editusers_api_key    = $config->{editusers_user_api_key};
my $insider_login        = $config->{QA_Selenium_TEST_user_login};
my $target_login         = $config->{editusers_target_user_login};
my $target_realname      = $config->{editusers_target_user_username};
my $url                  = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Read an account back as the admin. The request goes through the web server,
# so the object caches in this process know nothing about it. The admin is in
# the employee group, so the group list comes back unfiltered.
sub user_record {
  my ($login) = @_;
  $t->get_ok(
    $url . "rest/user/$login" => {'X-Bugzilla-API-Key' => $admin_api_key})
    ->status_is(200);
  return $t->tx->res->json->{users}[0];
}

my $admin_id = user_record($admin_login)->{id};

# Reset the name as the admin, so that the update below is a change even on a
# re-run of this test.
$t->put_ok($url
    . "rest/user/$target_login" => {'X-Bugzilla-API-Key' => $admin_api_key} =>
    json => {full_name => $target_realname})->status_is(200);

#
# 1. A caller without editusers cannot update anyone. This is the negative
#    control: REST authentication itself is working.
#
$t->put_ok($url
    . "rest/user/$target_login" =>
    {'X-Bugzilla-API-Key' => $unprivileged_api_key} => json =>
    {full_name => 'Should Not Happen'})
  ->status_is(401)
  ->json_is('/code', 304, 'Caller without editusers is rejected');

#
# 2. A caller with editusers can still update an ordinary account.
#
$t->put_ok($url
    . "rest/user/$target_login" =>
    {'X-Bugzilla-API-Key' => $editusers_api_key} => json =>
    {full_name => 'REST Target User Renamed'})->status_is(200)->json_is(
  '/users/0/changes/full_name/added',
  'REST Target User Renamed',
  'editusers can rename an unprotected account'
    );

#
# 3. The same caller cannot update an account in the admin group, by login...
#
$t->put_ok($url
    . "rest/user/$admin_login" => {'X-Bugzilla-API-Key' => $editusers_api_key} =>
    json                       => {full_name            => 'Pwned By Editusers'})
  ->status_is(401)
  ->json_is('/code', 304, 'editusers cannot update an admin account by login');

#
# ...nor by id.
#
$t->put_ok($url
    . "rest/user/$admin_id" => {'X-Bugzilla-API-Key' => $editusers_api_key} =>
    json                    => {full_name            => 'Pwned By Editusers'})
  ->status_is(401)
  ->json_is('/code', 304, 'editusers cannot update an admin account by id');

# The admin account was left alone.
is(user_record($admin_login)->{real_name},
  $admin_realname, 'The admin account was not modified');

#
# 4. Nor can it update an account in the insider group.
#
my $insider_group = Bugzilla->params->{insidergroup};
my $insider       = $insider_group ? user_record($insider_login) : undef;

SKIP: {
  skip 'insidergroup is not set', 5 unless $insider_group;
  skip "$insider_login is not in the $insider_group group", 5
    unless grep { $_->{name} eq $insider_group } @{$insider->{groups} || []};

  $t->put_ok($url
      . "rest/user/$insider_login" =>
      {'X-Bugzilla-API-Key' => $editusers_api_key} => json =>
      {full_name => 'Pwned By Editusers'})
    ->status_is(401)
    ->json_is('/code', 304,
    'editusers alone cannot update an insider group account');

  # Restore the name, so that a regression here does not leave a renamed
  # account behind for the tests that run after this one.
  $t->put_ok($url
      . "rest/user/$insider_login" => {'X-Bugzilla-API-Key' => $admin_api_key} =>
      json => {full_name => $insider->{real_name}})->status_is(200);
}

#
# 5. Admins are unaffected. The name is set to its current value so that no
#    other test sees a modified admin account.
#
$t->put_ok($url
    . "rest/user/$admin_login" => {'X-Bugzilla-API-Key' => $admin_api_key} =>
    json                       => {full_name            => $admin_realname})
  ->status_is(200)
  ->json_has('/users', 'An admin can still update an admin account');

done_testing();
