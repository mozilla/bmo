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
use Bugzilla::Bug;
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::Test::Util qw(issue_api_key);

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $admin = Bugzilla::User->new({name => 'admin@mozilla.bugs'});
my ($product)
  = grep { $_->is_active && @{$_->components} && @{$_->versions} }
  Bugzilla::Product->get_all;
plan skip_all => 'Need the admin user and a product with a component'
  unless $admin && $product;
my $component = $product->components->[0]->name;

# A bug reported by admin, for the frequent components list.
Bugzilla->set_user($admin);
Bugzilla::Bug->create({
  short_desc   => "ProdCompSearch frequent test $$",
  product      => $product->name,
  component    => $component,
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => $product->versions->[0]->name,
});

my %auth = ('X-Bugzilla-API-Key' => issue_api_key($admin->login)->api_key);
my $t    = Test::Mojo->new('Bugzilla::App');

$t->get_ok('/rest/prod_comp_search/find/'
    . $product->name . '::'
    . $component => \%auth => form => {limit => 1})->status_is(200)->json_is(
  '/products' => [
    {product => $product->name},
    {product => $product->name, component => $component}
  ],
  'product::component finds the component, limit applies'
    );

$t->get_ok("/rest/prod_comp_search/find/nosuchproduct$$")
  ->status_is(200)
  ->json_is('/products' => [], 'no match');

$t->get_ok('/rest/prod_comp_search/frequent')
  ->status_is(200)
  ->json_is('/results' => [], 'nothing for a signed out user');

$t->get_ok('/rest/prod_comp_search/frequent' => \%auth)
  ->status_is(200)
  ->json_has('/results/0', 'frequent components for the reporter');
ok(
  (
    grep { $_->{product} eq $product->name && $_->{component} eq $component }
      @{$t->tx->res->json->{results}}
  ),
  'the reported component is listed'
);

done_testing;
