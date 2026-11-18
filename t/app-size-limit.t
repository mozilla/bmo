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

# Empty setrlimit so the plugin does not cap this test process's memory.
use Bugzilla::Test::MockLocalconfig (size_limit => 750_000, setrlimit => '{}');
use Bugzilla;
use Bugzilla::App::Plugin::SizeLimit;
use Test2::V0;
use Test::Mojo;
use Mojolicious::Lite;

subtest 'vm_size_kb reads VmSize' => sub {
  skip_all 'no /proc/self/status' unless -r '/proc/self/status';
  my $size = Bugzilla::App::Plugin::SizeLimit::vm_size_kb();
  like($size, qr/^\d+$/, 'whole number of kB');
  ok($size > 1024, "plausible size ($size kB)");
};

subtest 'after_dispatch closes the worker only when over the limit' => sub {
  skip_all 'no /proc/self/status' unless -r '/proc/self/status';

  # Must be defined when register() runs, or it skips installing the hook.
  my $fake_size = 1;
  my $stops     = 0;
  my $mock_size = mock 'Bugzilla::App::Plugin::SizeLimit' =>
    (override => [vm_size_kb => sub {$fake_size}]);
  my $mock_loop
    = mock 'Mojo::IOLoop' => (override => [stop_gracefully => sub { $stops++ }]);

  plugin 'Bugzilla::App::Plugin::SizeLimit';
  get '/' => sub { shift->render(text => 'ok') };
  my $t = Test::Mojo->new;

  $fake_size = 749_999;
  $t->get_ok('/')->status_is(200)->header_isnt(Connection => 'close');
  is($stops, 0, 'under the limit: worker keeps running');

  $fake_size = 750_000;
  $t->get_ok('/')->status_is(200)->header_is(Connection => 'close');
  is($stops, 1, 'at the limit: worker stops gracefully');

  $fake_size = undef;
  $t->get_ok('/')->status_is(200)->header_isnt(Connection => 'close');
  is($stops, 1, 'size unavailable: no action');
};

done_testing;
