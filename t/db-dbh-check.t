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

# Only SELECT 1 is needed, so skip Bugzilla::Test::MockDB's schema setup.
use Bugzilla::Test::MockLocalconfig (
  db_driver => 'sqlite',
  db_name   => ':memory:'
);
use Bugzilla;
use Class::Method::Modifiers qw(install_modifier);
use Scalar::Util qw(refaddr);
use Test2::V0;

# Bugzilla::DB->dbh should only ask DBIx::Connector (which pings) once per
# request, not once per query.

my $checks = 0;
install_modifier('DBIx::Connector', 'before', 'dbh', sub { $checks++ });

my $db    = Bugzilla->dbh;
my $entry = sub { Bugzilla->request_cache->{bz_db_checked_dbh}{refaddr $db} };

Bugzilla->clear_request_cache;
$checks = 0;

subtest 'one check for many queries in a request' => sub {
  $db->selectrow_array('SELECT 1') for 1 .. 20;
  my $sth = $db->prepare('SELECT 1');
  $sth->execute;
  is($checks,  1,                   'connector consulted once');
  is($db->dbh, $db->connector->dbh, 'same handle as the connector');
};

subtest 'new request re-checks' => sub {
  Bugzilla->clear_request_cache;
  $checks = 0;
  $db->selectrow_array('SELECT 1') for 1 .. 5;
  is($checks, 1, 'checked again after clear_request_cache');
};

subtest 'long-running process re-checks after the interval' => sub {
  $checks = 0;
  $entry->()->{checked} -= Bugzilla::DB::DBH_CHECK_INTERVAL + 1;
  $db->selectrow_array('SELECT 1') for 1 .. 5;
  is($checks, 1, 'checked again once the interval passed');
};

subtest 'forked child re-checks' => sub {
  $checks = 0;
  $entry->()->{pid} = -1;
  $db->selectrow_array('SELECT 1');
  is($checks, 1, 'pid change forces a check');
};

subtest 'dropped handle reconnects' => sub {
  $db->dbh->disconnect;
  $checks = 0;
  is($db->selectrow_array('SELECT 1'), 1, 'query works after disconnect');
  is($checks,                          1, 'inactive handle forces a check');
};

done_testing;
