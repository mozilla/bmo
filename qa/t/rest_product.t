#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST calls to:                           #
# Product.get_selectable_products()                 #
# Product.get_enterable_products()                  #
# Product.get_accessible_products()                 #
# Product.get()                                      #
#   GET /rest/product_selectable                     #
#   GET /rest/product_enterable                      #
#   GET /rest/product_accessible                     #
#   GET /rest/product                                #
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

my $config     = get_config();
my $qa_api_key = $config->{QA_Selenium_TEST_user_api_key};
my $url        = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# Look up the product ids by name. We use QA_Selenium_TEST because that user
# can access all four products (including the group-restricted private one,
# which the admin account is not a member of).
my @product_names
  = ('Another Product', 'QA-Selenium-TEST', 'QA Entry Only', 'QA Search Only');
$t->get_ok(rest_get_url($url, 'rest/product', {names => \@product_names}) =>
    {'X-Bugzilla-API-Key' => $qa_api_key})->status_is(200);
my %products
  = map { $_->{name} => $_->{id} } @{$t->tx->res->json->{products}};

my $public    = $products{'Another Product'};
my $private   = $products{'QA-Selenium-TEST'};
my $no_entry  = $products{'QA Entry Only'};
my $no_search = $products{'QA Search Only'};
my %id_map    = reverse %products;

my $tests = {
  'QA_Selenium_TEST' => {
    selectable => [$public, $private, $no_entry, $no_search],
    enterable  => [$public, $private, $no_entry, $no_search],
    accessible => [$public, $private, $no_entry, $no_search],
  },
  'unprivileged' => {
    selectable     => [$public, $no_entry],
    not_selectable => $no_search,
    enterable      => [$public, $no_search],
    not_enterable  => $no_entry,
    accessible     => [$public, $no_entry, $no_search],
    not_accessible => $private,
  },
  '' => {
    selectable     => [$public, $no_entry],
    not_selectable => $no_search,
    enterable      => [$public, $no_search],
    not_enterable  => $no_entry,
    accessible     => [$public, $no_entry, $no_search],
    not_accessible => $private,
  },
};

foreach my $user (sort keys %$tests) {
  my @selectable     = @{$tests->{$user}{selectable}};
  my @enterable      = @{$tests->{$user}{enterable}};
  my @accessible     = @{$tests->{$user}{accessible}};
  my $not_selectable = $tests->{$user}{not_selectable};
  my $not_enterable  = $tests->{$user}{not_enterable};
  my $not_accessible = $tests->{$user}{not_accessible};

  my $api_key = $user ? $config->{"${user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $label   = $user || 'Logged-out user';

  $t->get_ok($url . 'rest/product_selectable' => $headers)->status_is(200);
  my $select_ids = $t->tx->res->json->{ids};
  foreach my $id (@selectable) {
    ok(grep($_ == $id, @$select_ids), "$label can select " . $id_map{$id});
  }
  if ($not_selectable) {
    ok(!grep($_ == $not_selectable, @$select_ids),
      "$label cannot select " . $id_map{$not_selectable});
  }

  $t->get_ok($url . 'rest/product_enterable' => $headers)->status_is(200);
  my $enter_ids = $t->tx->res->json->{ids};
  foreach my $id (@enterable) {
    ok(grep($_ == $id, @$enter_ids), "$label can enter " . $id_map{$id});
  }
  if ($not_enterable) {
    ok(!grep($_ == $not_enterable, @$enter_ids),
      "$label cannot enter " . $id_map{$not_enterable});
  }

  $t->get_ok($url . 'rest/product_accessible' => $headers)->status_is(200);

  $t->get_ok(
    rest_get_url($url, 'rest/product', {ids => \@accessible}) => $headers)
    ->status_is(200);
  my $got = $t->tx->res->json->{products};
  is(scalar @$got, scalar @accessible,
    "Product.get gets all " . scalar(@accessible) . " accessible products for $label.");

  if ($not_accessible) {
    $t->get_ok(
      rest_get_url($url, 'rest/product', {ids => [$not_accessible]}) => $headers)
      ->status_is(200);
    is(scalar @{$t->tx->res->json->{products}}, 0,
      "$label gets 0 products when asking for " . $id_map{$not_accessible});
  }
}

my $admin_headers = {'X-Bugzilla-API-Key' => $config->{admin_user_api_key}};

# A product can be fetched by id or by name in the path.
$t->get_ok($url . "rest/product/$public" => $admin_headers)->status_is(200)
  ->json_is('/products/0/name' => 'Another Product');
$t->get_ok($url . 'rest/product/Another Product' => $admin_headers)
  ->status_is(200)->json_is('/products/0/id' => $public);

# include_fields accepts a comma-separated list.
$t->get_ok($url . "rest/product/$public?include_fields=id,name" => $admin_headers)
  ->status_is(200);
is_deeply([sort keys %{$t->tx->res->json->{products}[0]}],
  ['id', 'name'], 'include_fields=id,name returns only those fields');

# At least one of ids, names or type is required.
$t->get_ok($url . 'rest/product' => $admin_headers)->status_is(400)
  ->json_like('/message' => qr/requires\s+that you set one of the following/);

# An unknown type is rejected.
$t->get_ok($url . 'rest/product?type=bogus' => $admin_headers)
  ->status_is(400)->json_like('/message' => qr/'bogus' is invalid/);

$t->options_ok($url . 'rest/product')->status_is(200)
  ->header_is('Allow' => 'GET, POST');

done_testing();
