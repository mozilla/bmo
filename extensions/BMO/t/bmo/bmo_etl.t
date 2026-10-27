#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5 qa/t/lib);

use Bugzilla;
use Bugzilla::Constants;

BEGIN {
  Bugzilla->extensions;
}

use Capture::Tiny qw(capture);
use DateTime;
use QA::Util     qw(get_config);
use MIME::Base64 qw(encode_base64 decode_base64);
use Mojo::JSON   qw(false);
use Test::Mojo;
use Test::More;

my $config           = get_config();
my $admin_login      = $config->{admin_user_login};
my $admin_api_key    = $config->{admin_user_api_key};
my $editbugs_api_key = $config->{editbugs_user_api_key};
my $url              = Bugzilla->localconfig->urlbase;
my $snapshot_date    = DateTime->now()->strftime('%Y-%m-%d');

my $t = Test::Mojo->new();

# Allow 1 redirect max
$t->ua->max_redirects(1);

### Section 1: Create new bug

my $new_bug_1 = {
  product     => 'Firefox',
  component   => 'General',
  summary     => 'This is a new test bug',
  type        => 'defect',
  version     => 'unspecified',
  severity    => 'blocker',
  description => 'This is a new test bug',
  flags       => [{
    name      => 'needinfo',
    status    => '?',
    requestee => $config->{editbugs_user_login},
  }],
};

$t->post_ok($url
    . 'rest/bug' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    $new_bug_1)->status_is(200)->json_has('/id');

my $bug_id_1 = $t->tx->res->json->{id};

# Clear the needinfo which will add an X entry in flag_state_activity
my $needinfo_update = {
  comment => {body => 'This is my comment'},
  flags   => [{name => 'needinfo', status => 'X'}],
};
$t->put_ok($url
    . "rest/bug/$bug_id_1" => {'X-Bugzilla-API-Key' => $editbugs_api_key} =>
    json                   => $needinfo_update)->status_is(200);

### Section 2: Create a new dependent bug

my $new_bug_2 = {
  product     => 'Firefox',
  component   => 'General',
  summary     => 'This is a new dependent bug',
  type        => 'defect',
  version     => 'unspecified',
  severity    => 'blocker',
  description => 'This is a new dependent bug',
  depends_on  => [$bug_id_1],
};

$t->post_ok($url
    . 'rest/bug' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    $new_bug_2)->status_is(200)->json_has('/id');

my $bug_id_2 = $t->tx->res->json->{id};

### Section 3: Create an attachment

my $attach_data = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX';

my $new_attach_1 = {
  is_patch     => 1,
  comment      => 'This is a new attachment',
  summary      => 'Test Attachment',
  content_type => 'text/plain',
  data         => encode_base64($attach_data),
  file_name    => 'test_attachment.patch',
  obsoletes    => [],
  is_private   => 0,
  flags        => [{
    name      => 'review',
    status    => '?',
    requestee => $config->{editbugs_user_login},
  }],
};

$t->post_ok($url
    . "rest/bug/$bug_id_1/attachment"        =>
    {'X-Bugzilla-API-Key' => $admin_api_key} => json => $new_attach_1)
  ->status_is(201)->json_has('/attachments');

my ($attach_id) = keys %{$t->tx->res->json->{attachments}};

### Section 4: Export data to test files

my @cmd = (
  './extensions/BMO/bin/export_bmo_etl.pl',
  '--test', '--snapshot-date', $snapshot_date,
);

my ($output, $error, $rv) = capture { system @cmd; };
ok(!$rv, 'Data exported to test files without error');
ok(glob(bz_locations()->{'datadir'} . '/' . $snapshot_date . '-bugs-*.json'),
  'Export test files exist');

### Section 5: Export data to BigQuery test instance

@cmd = (
  './extensions/BMO/bin/export_bmo_etl.pl',
  '--snapshot-date', $snapshot_date,
);

($output, $error, $rv) = capture { system @cmd; };
ok(!$rv, 'Data exported to BigQuery test instance without error');

### Section 6: Retrieve data from BigQuery instance and verify

my $query = {
  query => 'SELECT summary FROM test.bugzilla.bugs WHERE id = '
    . $bug_id_1
    . ' AND snapshot_date = \''
    . $snapshot_date . '\';',
  useLegacySql => false
};
$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/queries' => json => $query)
  ->status_is(200)->json_is('/rows/0/f/0/v' => $new_bug_1->{summary});

$query = {
  query => 'SELECT description FROM test.bugzilla.attachments WHERE id = '
    . $attach_id
    . ' AND snapshot_date = \''
    . $snapshot_date . '\';',
  useLegacySql => false
};
$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/queries' => json => $query)
  ->status_is(200)->json_is('/rows/0/f/0/v' => $new_attach_1->{summary});

$query = {
  query =>
    'SELECT depends_on_id FROM test.bugzilla.bug_dependencies WHERE bug_id = '
    . $bug_id_2
    . ' AND snapshot_date = \''
    . $snapshot_date . '\';',
  useLegacySql => false
};
$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/queries' => json => $query)
  ->status_is(200)->json_is('/rows/0/f/0/v' => $bug_id_1);

$query = {
  query => 'SELECT bug_id FROM test.bugzilla.flags WHERE bug_id = '
    . $bug_id_1
    . ' AND name = \'needinfo\' AND value = \'X\' AND snapshot_date = \''
    . $snapshot_date . '\'',
  useLegacySql => false
};
$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/queries' => json => $query)
  ->status_is(200)->json_is('/rows/0/f/0/v' => $bug_id_1);

$query = {
  query => 'SELECT bug_id FROM test.bugzilla.flags WHERE bug_id = '
    . $bug_id_1
    . ' AND name = \'review\' AND attachment_id = '
    . $attach_id
    . ' AND snapshot_date = \''
    . $snapshot_date . '\';',
  useLegacySql => false
};

$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/queries' => json => $query)
  ->status_is(200)->json_is('/rows/0/f/0/v' => $bug_id_1);

### Section 7: Exporting again with the same snapshot date succeeds without sending data again

@cmd = (
  './extensions/BMO/bin/export_bmo_etl.pl',
  '--debug', '--snapshot-date', $snapshot_date,
);

($output, $error, $rv) = capture { system @cmd; };
ok(!$rv, 'Exporting an already exported snapshot date exits successfully');

### Section 8: Each row is published exactly once and staging tables are removed

$query = {
  query => 'SELECT count(*) FROM test.bugzilla.bugs WHERE id = '
    . $bug_id_1
    . ' AND snapshot_date = \''
    . $snapshot_date . '\';',
  useLegacySql => false
};
$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/queries' => json => $query)
  ->status_is(200)
  ->json_is('/rows/0/f/0/v' => 1);

$t->get_ok('http://bq:9050/bigquery/v2/projects/test/datasets/bugzilla/tables')
  ->status_is(200);
my @staging = grep { $_->{tableReference}->{tableId} =~ /^etl_staging_/ }
  @{$t->tx->res->json->{tables} || []};
is(scalar @staging, 0, 'No staging tables left after export');

my $dbh        = Bugzilla->dbh;
my $lock_count = $dbh->selectrow_array('SELECT COUNT(*) FROM bmo_etl_locked');
is($lock_count, 0, 'Lock removed after export');

### Section 9: A live lock blocks the export, a stale lock is taken over

$dbh->do(
  'INSERT INTO bmo_etl_locked (value, creation_ts, updated_ts) VALUES (?, NOW(), NOW())',
  undef, 'live_run'
);

@cmd = (
  './extensions/BMO/bin/export_bmo_etl.pl',
  '--snapshot-date', '2000-01-01', '--lock-wait', 0,
);

($output, $error, $rv) = capture { system @cmd; };
ok($rv, 'Export should fail while another live export holds the lock');

# Only one lock row can exist, so two runs starting at once cannot both
# take the lock
my $second_lock = $dbh->do(
  'INSERT IGNORE INTO bmo_etl_locked (value, creation_ts, updated_ts) VALUES (?, NOW(), NOW())',
  undef, 'second_run'
);
ok(!($second_lock > 0), 'A second lock cannot be set while one is held');

# Simulate a run that was killed: its lock stopped being refreshed an hour
# ago and it left a staging table behind
$dbh->do('DELETE FROM bmo_etl_locked');
my $stale_ts = $dbh->selectrow_array(
  'SELECT ' . $dbh->sql_date_math('NOW()', '-', 1, 'HOUR'));
$dbh->do(
  'INSERT INTO bmo_etl_locked (value, creation_ts, updated_ts) VALUES (?, ?, ?)',
  undef, 'dead_run', $stale_ts, $stale_ts
);

$t->post_ok(
  'http://bq:9050/bigquery/v2/projects/test/datasets/bugzilla/tables' => json =>
    {
    tableReference =>
      {projectId => 'test', datasetId => 'bugzilla', tableId => 'etl_staging_bugs_dead'},
    schema => {fields => [{name => 'id', type => 'INTEGER'}]},
    }
)->status_is(200);

($output, $error, $rv) = capture { system @cmd; };
ok(!$rv, 'Export takes over a stale lock and finishes');

$lock_count = $dbh->selectrow_array('SELECT COUNT(*) FROM bmo_etl_locked');
is($lock_count, 0, 'Stale lock removed after export');

$t->get_ok('http://bq:9050/bigquery/v2/projects/test/datasets/bugzilla/tables')
  ->status_is(200);
@staging = grep { $_->{tableReference}->{tableId} =~ /^etl_staging_/ }
  @{$t->tx->res->json->{tables} || []};
is(scalar @staging, 0, 'Orphaned staging table dropped');

### Section 10: An invalid snapshot date is rejected

@cmd = (
  './extensions/BMO/bin/export_bmo_etl.pl',
  '--snapshot-date', "2000-01-01' OR '1'='1",
);

($output, $error, $rv) = capture { system @cmd; };
ok($rv, 'Export should fail with an invalid snapshot date');

$lock_count = $dbh->selectrow_array('SELECT COUNT(*) FROM bmo_etl_locked');
is($lock_count, 0, 'Invalid snapshot date does not leave a lock behind');

done_testing;
