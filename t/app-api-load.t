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

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;

use Test2::V0;
use Test::Mojo;

use Bugzilla::App::Controller::API;

# Bugzilla::API::V1 also holds helper modules that are not controllers, such
# as Util. Loading the routes must skip them rather than warn at every startup.
my @warnings;
my $mock = mock 'Bugzilla::App::Controller::API' =>
  (override => [WARN => sub { push @warnings, @_ }]);

my $t = Test::Mojo->new('Bugzilla::App');

is([grep {/^Bugzilla::API::/} @warnings],
  [], 'no core API module fails to load');

# The controllers next to it still get their routes.
$t->get_ok('/rest/whoami')->status_is(401)->json_is('/code' => 410);

done_testing;
