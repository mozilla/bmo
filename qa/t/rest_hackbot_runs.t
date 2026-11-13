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
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Bugzilla::Logging;

use QA::Util  qw(get_config);
use QA::Tests qw(create_bug_fields PRIVATE_BUG_USER);
use Test::Mojo;
use Test::More;

my $config           = get_config();
my $url              = Bugzilla->localconfig->urlbase;
my $admin_key        = $config->{admin_user_api_key};
my $editbugs_key     = $config->{editbugs_user_api_key};
my $unprivileged_key = $config->{unprivileged_user_api_key};
my $private_key      = $config->{PRIVATE_BUG_USER . '_user_api_key'};

my $t = Test::Mojo->new();

# The endpoint reads the run list from memcached before it would ever call the
# Hackbot API, so seeding a fresh cache entry lets us test it with no network.
sub seed_runs {
  my ($bug_id) = @_;
  Bugzilla->memcached->set_data({
    key   => "hackbot_runs.v1.$bug_id",
    value => {
      etag        => '"seeded"',
      fresh_until => time() + 300,
      runs        => [{
        run_id        => '53bbcc6e-014c-487b-b0e8-8a6b7b0ec273',
        agent         => 'bug-fix',
        status        => 'running',
        created_at    => '2026-11-12T16:24:39Z',
        requested_by  => undef,
        requested_via => undef,
        needinfo      => 1,
      }],
    },
    expires_in => 300,
  });
}

sub create_bug {
  my ($api_key, $summary) = @_;
  my $bug_data = create_bug_fields($config);
  delete $bug_data->{cc};
  $bug_data->{summary} = $summary;
  $t->post_ok(
    $url . 'rest/bug' => {'X-Bugzilla-API-Key' => $api_key} => json => $bug_data)
    ->status_is(200)
    ->json_has('/id');
  return $t->tx->res->json->{id};
}

my $bug_id = create_bug($editbugs_key, 'Test Hackbot runs');
seed_runs($bug_id);

# Login is required.
$t->get_ok($url . "rest/hackbot/bug_runs/$bug_id")->status_is(401);

# Only editbugs members may see Hackbot runs.
$t->get_ok($url
    . "rest/hackbot/bug_runs/$bug_id" =>
    {'X-Bugzilla-API-Key' => $unprivileged_key})
  ->json_is('/error', 1)
  ->json_hasnt('/runs');

# An editbugs member gets the runs, with no requester email exposed.
$t->get_ok($url
    . "rest/hackbot/bug_runs/$bug_id" => {'X-Bugzilla-API-Key' => $editbugs_key})
  ->status_is(200)
  ->json_is('/runs/0/run_id', '53bbcc6e-014c-487b-b0e8-8a6b7b0ec273')
  ->json_like('/runs/0/url', qr{/runs/53bbcc6e-014c-487b-b0e8-8a6b7b0ec273$})
  ->json_is('/runs/0/agent',  'bug-fix')
  ->json_is('/runs/0/status', 'running')
  ->json_is('/runs/0/origin', 'needinfo')
  ->json_hasnt('/runs/0/requested_by')
  ->json_hasnt('/runs/1');

# A non-numeric bug id is rejected.
$t->get_ok(
  $url . 'rest/hackbot/bug_runs/abc' => {'X-Bugzilla-API-Key' => $editbugs_key})
  ->json_is('/error', 1);

# Runs on a bug the user can't see are not shown, even to editbugs members.
# The editbugs user files the bug and, as its reporter, can still see it once
# it is in QA-Selenium-TEST. The admin is in editbugs but neither in that group
# (it is created so admin doesn't inherit it) nor the reporter, so is denied.
my $private_bug_id
  = create_bug($editbugs_key, 'Test Hackbot runs on a private bug');
$t->put_ok($url
    . "rest/bug/$private_bug_id" => {'X-Bugzilla-API-Key' => $private_key} =>
    json => {groups => {add => ['QA-Selenium-TEST']}})->status_is(200);
seed_runs($private_bug_id);

$t->get_ok($url
    . "rest/hackbot/bug_runs/$private_bug_id" =>
    {'X-Bugzilla-API-Key' => $admin_key})
  ->json_is('/error', 1)
  ->json_hasnt('/runs');

$t->get_ok($url
    . "rest/hackbot/bug_runs/$private_bug_id" =>
    {'X-Bugzilla-API-Key' => $editbugs_key})
  ->status_is(200)
  ->json_is('/runs/0/origin', 'needinfo');

done_testing();
