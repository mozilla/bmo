#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.legal_values()          #
# GET /rest/field/bug/<field>/values                 #
# GET /rest/field/bug/<field>/<product_id>/values    #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config);
use QA::REST::Util qw(api_headers rest_get_url);

use Test::Mojo;
use Test::More;

use constant INVALID_PRODUCT_ID => -1;
use constant INVALID_FIELD_NAME => 'invalid_field';
use constant GLOBAL_FIELDS =>
  qw(bug_type bug_severity bug_status op_sys priority rep_platform resolution
  cf_qa_status cf_single_select);
use constant PRODUCT_FIELDS => qw(version target_milestone component);

my $config     = get_config();
my $qa_api_key = $config->{QA_Selenium_TEST_user_api_key};
my $url        = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# Look up the product ids by name. We use QA_Selenium_TEST because that user
# can access the group-restricted private product (the admin account is not a
# member of its group).
$t->get_ok(
  rest_get_url($url, 'rest/product', {names => ['Another Product', 'QA-Selenium-TEST']})
    => {'X-Bugzilla-API-Key' => $qa_api_key})->status_is(200);
my %products = map { $_->{name} => $_->{id} } @{$t->tx->res->json->{products}};
my $public_product  = $products{'Another Product'};
my $private_product = $products{'QA-Selenium-TEST'};

my @all_tests;

for my $field (GLOBAL_FIELDS) {
  push(@all_tests,
    {path => "$field/values", test => "Logged-out user can get $field values"});
}

for my $field (PRODUCT_FIELDS) {
  push(@all_tests,
    {
      path  => "$field/values",
      error => "argument was not set",
      test  => "$field can't be accessed without a value for 'product'",
    },
    {
      path  => "$field/" . INVALID_PRODUCT_ID . "/values",
      error => "does not exist",
      test  => "$field cannot be accessed with an invalid product id",
    },
    {
      path  => "$field/$private_product/values",
      error => "you don't have access",
      test  => "Logged-out user cannot access $field in private product"
    },
    {
      path => "$field/$public_product/values",
      test => "Logged-out user can access $field in a public product",
    },
    {
      user  => 'unprivileged',
      path  => "$field/$private_product/values",
      error => "you don't have access",
      test  => "Unprivileged user cannot access $field in private product",
    },
    {
      user => 'unprivileged',
      path => "$field/$public_product/values",
      test => "Logged-in user can access $field in public product",
    },
    {
      user => 'QA_Selenium_TEST',
      path => "$field/$private_product/values",
      test => "Privileged user can access $field in a private product",
    },
  );
}

push(@all_tests,
  {
    path  => INVALID_FIELD_NAME . "/values",
    error => "Can't use " . INVALID_FIELD_NAME . " as a field name",
    test  => 'Invalid field name'
  },
);

foreach my $test (@all_tests) {
  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $path    = $url . "rest/field/bug/$test->{path}";

  if (my $error = $test->{error}) {
    $t->get_ok($path => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
  }
  else {
    $t->get_ok($path => $headers)->status_is(200);
    cmp_ok(scalar @{$t->tx->res->json->{values}}, '>', 0, "$test->{test}: got values");
  }
}

$t->get_ok($url . "rest/field/bug/version/values?product_id=$public_product" =>
    api_headers(undef))->status_is(200);
cmp_ok(scalar @{$t->tx->res->json->{values}},
  '>', 0, 'product_id can be passed as a query parameter');

done_testing();
