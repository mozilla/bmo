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

BEGIN { $ENV{LOG4PERL_CONFIG_FILE} = 'log4perl-t.conf' }

use Bugzilla::Test::MockLocalconfig ();
use Bugzilla;
use Bugzilla::Memcached;
use Bugzilla::Util qw(fetch_product_versions);
use Test2::V0;

# fetch_product_versions should consult memcached and the endpoint at most
# once per product per request, including when the endpoint is failing.

my $endpoint = 'https://product-details.example';
my %memcached;
my ($http_calls, $memcached_gets, $http_ok) = (0, 0, 1);

my $mock_bugzilla = mock 'Bugzilla' =>
  (override => [params => sub { {product_details_endpoint => $endpoint} }]);

my $mock_memcached = mock 'Bugzilla::Memcached' => (
  override => [
    get_data => sub { $memcached_gets++; $memcached{$_[1]{key}} },
    set_data => sub { $memcached{$_[1]{key}} = $_[1]{value} },
  ]
);

my $mock_util = mock 'Bugzilla::Util' => (
  override => [
    mojo_user_agent => sub {
      mock {} => (
        add => [
          get => sub {
            $http_calls++;
            mock {} => (
              add => [
                result => sub {
                  mock {} => (
                    add => [
                      is_success => sub {$http_ok},
                      body       => sub {'{"LATEST_FIREFOX_VERSION":"140.0"}'},
                      code       => sub {500},
                      message    => sub {'Internal Server Error'},
                    ]
                  );
                }
              ]
            );
          }
        ]
      );
    }
  ]
);

sub new_request {
  Bugzilla->clear_request_cache;
  ($http_calls, $memcached_gets) = (0, 0);
}

subtest 'endpoint failing: one attempt per request' => sub {
  new_request();
  $http_ok = 0;
  is(fetch_product_versions('firefox'), undef, 'undef on failure') for 1 .. 5;
  is($http_calls,                       1,     'endpoint called once');
  is($memcached_gets,                   1,     'memcached checked once');

  new_request();
  fetch_product_versions('firefox');
  is($http_calls, 1, 'next request tries again');
};

subtest 'endpoint ok: fetched once, then served from memcached' => sub {
  new_request();
  $http_ok = 1;
  is(
    fetch_product_versions('firefox'),
    {LATEST_FIREFOX_VERSION => '140.0'},
    'versions returned'
  ) for 1 .. 5;
  is($http_calls,     1, 'endpoint called once');
  is($memcached_gets, 1, 'memcached checked once');

  new_request();
  fetch_product_versions('firefox') for 1 .. 5;
  is($http_calls,     0, 'later request does not call the endpoint');
  is($memcached_gets, 1, 'memcached hit is reused within the request');
};

subtest 'products are cached separately' => sub {
  new_request();
  %memcached = ();
  fetch_product_versions($_) for qw(firefox thunderbird firefox thunderbird);
  is($http_calls, 2, 'one fetch per product');
};

subtest 'no endpoint configured' => sub {
  new_request();
  %memcached = ();
  my $saved = $endpoint;
  $endpoint = '';
  is(fetch_product_versions('firefox'), undef, 'undef') for 1 .. 3;
  is($http_calls,                       0,     'no HTTP call');
  is($memcached_gets,                   1,     'memcached checked once');
  $endpoint = $saved;
};

done_testing;
