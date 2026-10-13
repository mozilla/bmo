#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Group.create()              #
# POST /rest/group                                   #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config random_string);

use Test::Mojo;
use Test::More;

use constant DESCRIPTION => 'Group created by Group.create';

my $config = get_config();
my $url    = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

my @tests = (
  {
    args  => {name => random_string(20), description => DESCRIPTION},
    error => 'You must log in',
    test  => 'Logged-out user cannot call Group.create',
  },
  {
    user  => 'unprivileged',
    args  => {name => random_string(20), description => DESCRIPTION},
    error => 'you are not authorized',
    test  => 'Unprivileged user cannot call Group.create',
  },
  {
    user  => 'admin',
    args  => {description => DESCRIPTION},
    error => 'You must enter a name',
    test  => 'Missing name to Group.create',
  },
  {
    user  => 'admin',
    args  => {name => random_string(20)},
    error => 'You must enter a description',
    test  => 'Missing description to Group.create',
  },
  {
    user  => 'admin',
    args  => {name => '', description => DESCRIPTION},
    error => 'You must enter a name',
    test  => 'Name to Group.create cannot be empty',
  },
  {
    user  => 'admin',
    args  => {name => random_string(20), description => ''},
    error => 'You must enter a description',
    test  => 'Description to Group.create cannot be empty',
  },
  {
    user  => 'admin',
    args  => {name => 'canconfirm', description => DESCRIPTION},
    error => 'already exists',
    test  => 'Name to Group.create already exists',
  },
  {
    user  => 'admin',
    args  => {name => 'caNConFIrm', description => DESCRIPTION},
    error => 'already exists',
    test  => 'Name to Group.create already exists but with a different case',
  },
  {
    user  => 'admin',
    args  => {name => random_string(20), description => DESCRIPTION, user_regexp => '\\'},
    error => 'The regular expression you entered is invalid',
    test  => 'The regular expression passed to Group.create is invalid',
  },
  {
    user => 'admin',
    args => {name => random_string(20), description => DESCRIPTION},
    test => 'Passing the name and description only works',
  },
  {
    user => 'admin',
    args => {
      name        => random_string(20),
      description => DESCRIPTION,
      user_regexp => '\@foo.com$',
      is_active   => 1,
      icon_url    => 'https://www.bugzilla.org/favicon.ico'
    },
    test => 'Passing all arguments works',
  },
);

foreach my $test (@tests) {
  my %headers;
  if (my $user = $test->{user}) {
    $headers{'X-Bugzilla-API-Key'} = $config->{"${user}_user_api_key"};
  }

  if (my $error = $test->{error}) {
    $t->post_ok(
      $url . 'rest/group' => \%headers => json => $test->{args})->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
  }
  else {
    $t->post_ok(
      $url . 'rest/group' => \%headers => json => $test->{args})->status_is(201);
    ok($t->tx->res->json->{id}, "$test->{test}: got a non-zero group id");
  }
}

# A form body sends is_active as the string "true" or "false": "false" must
# not be stored as true, on create or on update.
my %admin = ('X-Bugzilla-API-Key' => $config->{admin_user_api_key});

$t->post_ok($url
    . 'rest/group' => \%admin => form =>
    {name => random_string(20), description => DESCRIPTION, is_active => 'false'})
  ->status_is(201);
my $group_id = $t->tx->res->json->{id};

$t->get_ok($url . "rest/group/$group_id" => \%admin)->status_is(200);
ok(!$t->tx->res->json->{groups}[0]{is_active},
  'is_active=false in a form body creates an inactive group');

$t->put_ok(
  $url . "rest/group/$group_id" => \%admin => form => {is_active => 'true'})
  ->status_is(200)
  ->json_is('/groups/0/changes/is_active/added', '1');

$t->put_ok(
  $url . "rest/group/$group_id" => \%admin => form => {is_active => 'false'})
  ->status_is(200)
  ->json_is('/groups/0/changes/is_active/added', '0');

$t->put_ok(
  $url . "rest/group/$group_id" => \%admin => form => {is_active => 'maybe'})
  ->status_is(400)
  ->json_like('/message' => qr/is_active must be true or false/);

$t->post_ok($url
    . 'rest/group' => \%admin => form =>
    {name => random_string(20), description => DESCRIPTION, is_active => 'maybe'})
  ->status_is(400)
  ->json_like('/message' => qr/is_active must be true or false/);

done_testing();
