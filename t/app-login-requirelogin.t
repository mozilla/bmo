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
use Bugzilla::Test::MockParams (requirelogin => 1, useclassification => 1);
use Bugzilla::Test::Util qw(create_user issue_api_key);

use Bugzilla::Config;
use Bugzilla::Constants;
use Test2::V0;
use Test::Mojo;

# With requirelogin on, native REST endpoints that otherwise allow anonymous
# access must refuse anonymous requests with login_required (internal code
# 410, HTTP 401), as the legacy dispatcher's Bugzilla->login() does. Two kinds
# of route are covered: /rest/configuration authenticates while still in
# USAGE_MODE_REST, /rest/classification/<id> and /rest/product_accessible
# after switching to USAGE_MODE_MOJO_REST.

create_user('requirelogin@mozilla.org', '*');
my $api_key = issue_api_key('requirelogin@mozilla.org')->api_key;

my $t = Test::Mojo->new('Bugzilla::App');

my @routes
  = ('/rest/configuration', '/rest/classification/1', '/rest/product_accessible');

foreach my $route (@routes) {
  $t->get_ok($route)->status_is(401)->json_is('/code' => 410);

  # An authenticated request is not refused.
  $t->get_ok($route => {'X-Bugzilla-API-Key' => $api_key})->status_isnt(401);
}

# With requirelogin off, the same anonymous requests are let through again.
my $params = Bugzilla::Config->new;
$params->set_param('requirelogin', 0);
$params->update();

foreach my $route (@routes) {
  $t->get_ok($route)->status_isnt(401);
}

done_testing;
