#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.flag_types()            #
# GET /rest/flag_types/<product>                     #
# GET /rest/flag_types/<product>/<component>         #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use List::Util     qw(first);
use QA::Util       qw(get_config);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

# spec_multi_flag is created by generate_test_data.pl for 'Another Product:c1'
# only, with editbugs as grant group and no request group.
use constant FLAG_NAME => 'spec_multi_flag';

my $config        = get_config();
my $admin_api_key = $config->{admin_user_api_key};
my $url           = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

sub get_flag {
  my ($path, $api_key) = @_;
  $t->get_ok($url . "rest/flag_types/$path" => api_headers($api_key))
    ->status_is(200)
    ->json_has('/bug')
    ->json_has('/attachment');
  return first { $_->{name} eq FLAG_NAME } @{$t->tx->res->json->{bug}};
}

my $flag = get_flag('Another Product');
ok($flag, FLAG_NAME . ' is returned for its product');
like($flag->{id}, qr/^\d+$/, 'id is numeric');
is($flag->{type}, 'bug', 'type is bug');
ok($flag->{is_requesteeble},  'is_requesteeble is true');
ok($flag->{is_multiplicable}, 'is_multiplicable is true');
is_deeply($flag->{inclusions}, ['c1'],     'inclusions lists the component');
is_deeply($flag->{values},     ['X', '?'], 'Logged-out user can only request');

$flag = get_flag('Another Product', $admin_api_key);
is_deeply($flag->{values}, ['X', '?', '+', '-'], 'editbugs user can also set');

ok(get_flag('Another Product/c1'),  FLAG_NAME . ' is returned for c1');
ok(!get_flag('Another Product/c2'), FLAG_NAME . ' is not returned for c2');
ok(
  get_flag('Another Product?component=c1'),
  'component can be passed as a query parameter'
);
ok(
  !get_flag('Another Product/c2?component=c1'),
  'component in the path wins over the query parameter'
);

$t->get_ok($url . 'rest/flag_types/No Such Product' => api_headers(undef))
  ->status_isnt(200)
  ->json_like('/message' => qr/does not exist/);
$t->get_ok($url
    . 'rest/flag_types/Another Product/No Such Component' => api_headers(undef))
  ->status_isnt(200)
  ->json_like('/message' => qr/No Such Component/);

$t->options_ok($url . 'rest/flag_types/Another Product/c1')
  ->status_is(200)
  ->header_is('Allow' => 'GET');

done_testing();
