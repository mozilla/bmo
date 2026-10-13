#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Product.create()            #
# POST /rest/product                                 #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config random_string);

use Mojo::JSON qw(false);
use Test::Mojo;
use Test::More;

use constant DESCRIPTION  => 'Product created by Product.create';
use constant PROD_VERSION => 'unspecified';

my $config        = get_config();
my $admin_api_key = $config->{admin_user_api_key};
my $url           = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

my @tests = (
  {
    args => {name => random_string(20), version => PROD_VERSION, description => DESCRIPTION},
    error => 'You must log in',
    test  => 'Logged-out user cannot call Product.create',
  },
  {
    user => 'unprivileged',
    args => {name => random_string(20), version => PROD_VERSION, description => DESCRIPTION},
    error => 'you are not authorized',
    test  => 'Unprivileged user cannot call Product.create',
  },
  {
    user  => 'admin',
    args  => {version => PROD_VERSION, description => DESCRIPTION},
    error => 'You must enter a name',
    test  => 'Missing name to Product.create',
  },
  {
    user  => 'admin',
    args  => {name => random_string(20), version => PROD_VERSION},
    error => 'You must enter a description',
    test  => 'Missing description to Product.create',
  },
  {
    user  => 'admin',
    args  => {name => '', version => PROD_VERSION, description => DESCRIPTION},
    error => 'You must enter a name',
    test  => 'Name to Product.create cannot be empty',
  },
  {
    user  => 'admin',
    args  => {name => random_string(20), version => PROD_VERSION, description => ''},
    error => 'You must enter a description',
    test  => 'Description to Product.create cannot be empty',
  },
  {
    user  => 'admin',
    args  => {name => random_string(20000), version => PROD_VERSION, description => DESCRIPTION},
    error => 'The name of a product is limited',
    test  => 'Name to Product.create too long',
  },
  {
    user  => 'admin',
    args  => {name => 'Another Product', version => PROD_VERSION, description => DESCRIPTION},
    error => 'already exists',
    test  => 'Name to Product.create already exists',
  },
  {
    user  => 'admin',
    args  => {name => 'aNoThEr Product', version => PROD_VERSION, description => DESCRIPTION},
    error => 'differs from existing product',
    test  => 'Name to Product.create already exists but with a different case',
  },
  {
    user => 'admin',
    args => {name => random_string(20), version => PROD_VERSION, description => DESCRIPTION},
    test => 'Passing the name, description and version only works',
  },
  {
    user => 'admin',
    args => {
      name              => random_string(20),
      default_version   => PROD_VERSION,
      description       => DESCRIPTION,
      has_unconfirmed   => 1,
      classification    => 'Class2_QA',
      default_milestone => '2.0',
      is_open           => 1,
      create_series     => 1
    },
    test => 'Passing all arguments works',
  },
  {
    user => 'admin',
    args => {
      name              => random_string(20),
      default_version   => PROD_VERSION,
      description       => DESCRIPTION,
      has_unconfirmed   => 0,
      classification    => 'Class2_QA',
      default_milestone => '2.0',
      is_open           => 0,
      create_series     => 0
    },
    test => 'Passing null values works',
  },
  {
    user => 'admin',
    args => {
      name              => random_string(20),
      default_version   => PROD_VERSION,
      description       => DESCRIPTION,
      has_unconfirmed   => 1,
      classification    => 'Class2_QA',
      default_milestone => '',
      is_open           => 1,
      create_series     => 1
    },
    test => 'Passing an empty default milestone works (falls back to "---")',
  },
);

foreach my $test (@tests) {
  my %headers;
  if (my $user = $test->{user}) {
    $headers{'X-Bugzilla-API-Key'} = $config->{"${user}_user_api_key"};
  }

  if (my $error = $test->{error}) {
    $t->post_ok(
      $url . 'rest/product' => \%headers => json => $test->{args})->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
    next;
  }

  $t->post_ok(
    $url . 'rest/product' => \%headers => json => $test->{args})->status_is(201);
  my $prod_id = $t->tx->res->json->{id};
  ok($prod_id, "$test->{test}: got a non-zero product id");

  # Retrieve the product and verify is_active/has_unconfirmed defaults.
  $t->get_ok($url . "rest/product/$prod_id" =>
      {'X-Bugzilla-API-Key' => $admin_api_key})->status_is(200);
  my $product   = $t->tx->res->json->{products}[0];
  my $is_active = defined $test->{args}{is_open} ? $test->{args}{is_open} : 1;
  is($product->{is_active}, $is_active,
    "Product has the correct value for is_active/is_open: $is_active");
  my $has_unco = defined $test->{args}{has_unconfirmed} ? $test->{args}{has_unconfirmed} : 1;
  is($product->{has_unconfirmed}, $has_unco,
    "Product has the correct value for has_unconfirmed: $has_unco");
}

# Booleans passed in the query string arrive as the strings "true"/"false"
# and must not all be treated as true.
my $qs_name = random_string(20);
$t->post_ok($url
    . "rest/product?name=$qs_name&description=Created%20via%20query%20string"
    . '&version=' . PROD_VERSION
    . '&is_open=false&has_unconfirmed=false' =>
    {'X-Bugzilla-API-Key' => $admin_api_key})->status_is(201);
my $qs_id = $t->tx->res->json->{id};
$t->get_ok($url . "rest/product/$qs_id" => {'X-Bugzilla-API-Key' => $admin_api_key})
  ->status_is(200)->json_is('/products/0/is_active' => false)
  ->json_is('/products/0/has_unconfirmed' => false);

$t->post_ok($url
    . 'rest/product?name=' . random_string(20)
    . '&description=x&version=' . PROD_VERSION . '&is_open=maybe' =>
    {'X-Bugzilla-API-Key' => $admin_api_key})->status_is(400)
  ->json_like('/message' => qr/is_open must be true or false/);

done_testing();
