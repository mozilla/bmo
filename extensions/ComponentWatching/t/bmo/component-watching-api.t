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

use Test::More;
use Test::Mojo;

use Bugzilla;
BEGIN { Bugzilla->extensions }
use Bugzilla::Constants;
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::Test::Util qw(issue_api_key);

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my @users = map {
  Bugzilla::User->create({
    login_name => "component-watching-$_-$$\@bmo.tld", cryptpassword => '*',
  })
} qw(a b);

my ($product) = grep {
  $_->is_active && @{$_->components} >= 2 && $users[0]->can_access_product($_)
} Bugzilla::Product->get_all;
plan skip_all => 'Need a product with two components' unless $product;
my ($c0,     $c1) = map { $_->name } @{$product->components};
my ($auth_a, $auth_b)
  = map { {'X-Bugzilla-API-Key' => issue_api_key($_->login)->api_key} } @users;
my $t = Test::Mojo->new('Bugzilla::App');

# Login is required.
$t->get_ok('/rest/component-watching')
  ->status_is(401)
  ->json_is('/error' => 1, 'list needs a login');
$t->post_ok('/rest/component-watching' => json => {product => $product->name})
  ->status_is(401);

$t->get_ok('/rest/component-watching' => $auth_a)
  ->status_is(200)
  ->json_is('' => [], 'no watches yet');

# Product watch, from a JSON body.
$t->post_ok('/rest/component-watching' => $auth_a => json =>
    {product => $product->name, component => ''})
  ->status_is(200)
  ->json_is('/product_name'   => $product->name)
  ->json_is('/component_name' => '', 'product watch');
my $product_watch = $t->tx->res->json->{id};
ok($product_watch, 'the new watch has an id');

my ($settings) = Bugzilla->dbh->selectrow_array(
  'SELECT COUNT(*) FROM email_setting WHERE user_id = ? AND relationship = ?',
  undef,
  $users[0]->id,
  Bugzilla::Extension::ComponentWatching::REL_COMPONENT_WATCHER
);
ok($settings, 'default email settings added');

$t->post_ok(
  '/rest/component-watching' => $auth_a => json => {product => $product->name})
  ->status_is(200)
  ->content_is('null', 'already watched');
$t->post_ok('/rest/component-watching' => $auth_a => form =>
    {product => $product->name, component => $c0})
  ->status_is(200)
  ->content_is('null', 'component covered by the product watch');

# Component watches, one from a list in the query string, one from a JSON list.
$t->post_ok("/rest/component-watching" => $auth_b => form =>
    {product => $product->name, component => [$c0, $c1]})
  ->status_is(200)
  ->json_is('/component_name' => $c1, 'last component watch returned');
$t->get_ok('/rest/component-watching' => $auth_b)
  ->status_is(200)
  ->json_is('/0/component_name' => (sort $c0, $c1)[0])
  ->json_is('/1/component_name' => (sort $c0, $c1)[1])
  ->json_hasnt('/2', 'both components watched, sorted');
my @b_watches = map { $_->{id} } @{$t->tx->res->json};

# Errors.
$t->post_ok(
  '/rest/component-watching' => $auth_a => json => {product => 'No such product'})
  ->json_is('/error' => 1)
  ->json_like(
  '/message' => qr/'No such product'\s+does not exist/,
  'unknown product'
  );
$t->post_ok('/rest/component-watching' => $auth_a => json =>
    {product => $product->name, component => ['No such component']})
  ->json_is('/error' => 1, 'unknown component');

# Get one watch; another user's watch isn't found.
$t->get_ok("/rest/component-watching/$product_watch" => $auth_a)
  ->status_is(200)
  ->json_is('/id'           => $product_watch)
  ->json_is('/product_name' => $product->name, 'own watch');
$t->get_ok("/rest/component-watching/$product_watch" => $auth_b)
  ->status_is(200)
  ->json_is('' => {}, "someone else's watch");

# Delete only removes the user's own watches.
$t->delete_ok("/rest/component-watching/$product_watch" => $auth_b)
  ->status_is(200)
  ->json_is('/status' => '0E0', "someone else's watch is kept");
$t->delete_ok("/rest/component-watching/$product_watch" => $auth_a)
  ->status_is(200)
  ->json_is('/status' => 1, 'own watch removed');
$t->get_ok('/rest/component-watching' => $auth_a)->json_is('' => [], 'gone');
$t->get_ok('/rest/component-watching' => $auth_b)
  ->json_is('/0/id' => $b_watches[0], 'the other user keeps theirs');

done_testing;
