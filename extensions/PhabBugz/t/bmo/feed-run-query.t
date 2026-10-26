#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Feed::run_query, the wrapper the daemon's timers call for the
# feed, user and group loops: errors are logged and swallowed so the daemon
# keeps running, the watchdog alarm is armed during a query and cleared
# afterwards, and the request is cleaned up every time.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test2::Tools::Mock qw(mock);
use Test::More;

use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Feed;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $feed    = Bugzilla::Extension::PhabBugz::Feed->new;

$conduit->add_project(project_obj(name => 'secure-revision'));
$env->save_cursor('feed', 9_000_000);
$env->save_cursor('user', 900_000_000);

my @fatal;
my $logger = mock 'Bugzilla::Extension::PhabBugz::Feed' =>
  (override => [FATAL => sub { push @fatal, join('', @_) }]);

# Bugzilla->_cleanup clears the request cache (and with it the test user
# and params), so count the calls and restore the test request instead.
my $cleanups = 0;
my $cleanup
  = mock 'Bugzilla' => (override => [_cleanup => sub { $cleanups++ }]);

# Methods each loop calls first, so one failing reply hits every loop.
my @first_methods
  = qw(feed.query_id user.search bugzilla.account.search project.search);

sub run {
  my ($name) = @_;
  @fatal    = ();
  $cleanups = 0;
  return $env->run_sync(sub { $feed->run_query($name) });
}

foreach my $case (
  ['network error', network_error('Connection refused')],
  ['HTTP 500',      http_error(500)],
  ['non-JSON body', invalid_json()],
  ['Conduit error', conduit_error('ERR-CONDUIT-CORE', 'Database is read-only')],
  )
{
  my ($name, $reply) = @$case;
  $conduit->on($_ => $reply) for @first_methods;

  foreach my $query (qw(feed user group)) {
    my $error = run($query);
    ok(!$error, "$query, $name: run_query does not die");
    is(scalar @fatal, 1, "$query, $name: error logged as FATAL");
    is(alarm(0),      0, "$query, $name: watchdog alarm cleared");
    is($cleanups,     1, "$query, $name: request cleaned up");
  }

  $conduit->off($_) for @first_methods;
}

# A successful run arms the watchdog alarm for the duration of the query
{
  my $armed;
  $conduit->on(
    'feed.query_id' => sub {
      my ($params, $c) = @_;
      $armed = alarm(0);
      alarm($armed);
      return $c->default_reply('feed.query_id', $params);
    }
  );
  ok(!run('feed'), 'feed run_query succeeds');
  is_deeply(\@fatal, [], 'nothing logged as FATAL');
  ok(
    $armed > 0 && $armed <= PHAB_TIMEOUT,
    'alarm set to PHAB_TIMEOUT ('
      . PHAB_TIMEOUT
      . "s) during the query, saw $armed"
  );
  is(alarm(0),  0, 'alarm cleared afterwards');
  is($cleanups, 1, 'request cleaned up after success');
  $conduit->off('feed.query_id');
}

# The daemon keeps going after failures
{
  ok(!run('user'), 'user run_query succeeds after earlier failures');
  is_deeply(\@fatal, [], 'nothing logged as FATAL');
  ok(!run('group'), 'group run_query succeeds after earlier failures');
  is_deeply(\@fatal, [], 'nothing logged as FATAL');
}

# An unknown query name is logged, not fatal to the caller
{
  ok(!run('bogus'), 'unknown query does not die');
  like($fatal[0] // '', qr/bogus_query/, 'unknown query method logged');
}

$env->fresh_request;
$env->finish;
done_testing;
