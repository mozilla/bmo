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
use QA::Util qw(get_config);

use Test::Mojo;
use Test::More;

my $config             = get_config();
my $admin_user_api_key = $config->{'admin_user_api_key'};
my $bot_user_api_key   = $config->{'automation_user_api_key'};
my $url                = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# No products specified should only include Firefox for this test
$t->get_ok($url
    . 'rest/bug/1?include_fields=last_change_time' =>
    {'X-Bugzilla-API-Key' => $admin_user_api_key})->status_is(200);
my $data = $t->tx->res->json;
my $old_timestamp = $data->{bugs}->[0]->{last_change_time};

# Add a comment as the normal user (admin)
my $update_bug = {comment => {body => 'Updating bug report'}};
$t->put_ok($url
    . 'rest/bug/1' => {'X-Bugzilla-API-Key' => $admin_user_api_key} => json =>
    $update_bug)->status_is(200);

# Retrieve the updated timestamps for comparison
$t->get_ok($url
    . "rest/bug/1?include_fields=last_change_time,last_change_time_non_bot" =>
    {'X-Bugzilla-API-Key' => $admin_user_api_key})->status_is(200);
$data = $t->tx->res->json;
my $current_timestamp         = $data->{bugs}->[0]->{last_change_time};
my $current_non_bot_timestamp = $data->{bugs}->[0]->{last_change_time_non_bot};
ok(
  $current_timestamp ne $old_timestamp,
  "Normal timestamp is different than before"
);
ok(
  $current_timestamp eq $current_non_bot_timestamp,
  "Normal timestamp is equal to non-bot timestamp"
);
$old_timestamp = $current_timestamp;

# Long enough for the timestamps to differ, and shorter than the server's
# 5 second keep-alive timeout: the next request reuses the connection, which
# fails if the server closes it at the same time.
sleep(2);

# Add a comment as a bot user
$t->put_ok($url
    . 'rest/bug/1' => {'X-Bugzilla-API-Key' => $bot_user_api_key} => json =>
    $update_bug)->status_is(200);
$data = $t->tx->res->json;

# Retrieve the updated timestamps for comparison
$t->get_ok($url
    . "rest/bug/1?include_fields=last_change_time,last_change_time_non_bot" =>
    {'X-Bugzilla-API-Key' => $admin_user_api_key})->status_is(200);
$data = $t->tx->res->json;
$current_timestamp         = $data->{bugs}->[0]->{last_change_time};
$current_non_bot_timestamp = $data->{bugs}->[0]->{last_change_time_non_bot};

# The normal timestamp is always updated
ok(
  $current_timestamp ne $old_timestamp,
  "Normal timestamp is different than before"
);

# Non-bot timestamp should be equal to the previous normal timestamp.
ok(
  $old_timestamp eq $current_non_bot_timestamp,
  "Normal timestamp is equal to non-bot timestamp"
);

done_testing();
