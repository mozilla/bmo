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
use lib qw(. lib local/lib/perl5);

use Bugzilla;
use Bugzilla::Attachment;
use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Flag;
use Bugzilla::Group;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::FlagActivity;

use HTTP::Headers;
use HTTP::Request;
use IO::Compress::Gzip     qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use List::Util             qw(any);
use LWP::UserAgent::Determined;
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json false true);
use Mojo::Util qw(getopt);
use Try::Tiny;

# BigQuery API cannot handle payloads larger than 10MB so
# we will send data in blocks.
use constant API_BLOCK_COUNT => 500;

# Products which we should not send data to ETL such as Legal, etc.
use constant EXCLUDE_PRODUCTS => ('Legal',);

# Every BigQuery table this script writes to. Each run streams rows into a
# staging copy of these tables and then publishes them all in one transaction.
use constant BQ_TABLES => qw(
  bugs attachments flags tracking_flags keywords see_also users
  bug_mentors bug_dependencies bug_regressions bug_duplicates
);

# Prefix for staging tables, and how long they live if a run is killed
# before it can drop them.
use constant STAGING_PREFIX   => 'etl_staging_';
use constant STAGING_LIFETIME => 2 * 24 * 60 * 60;    # two days

# Extra staging column holding a per-row key, used to drop rows that were
# sent twice when an insert request was retried
use constant STAGING_ROW_KEY => q(_etl_row);

# How long to wait for a BigQuery query (such as the publish transaction)
use constant QUERY_MAX_WAIT => 60 * 60;               # one hour

# A running export refreshes its lock at least this often. A lock not
# refreshed within LOCK_STALE_AFTER was left by a run that died, so a new run
# (such as a Kubernetes retry) takes it over. By default a new run waits up to
# LOCK_MAX_WAIT for an existing lock to be released or go stale.
use constant LOCK_REFRESH_EVERY => 60;                # one minute
use constant LOCK_STALE_AFTER   => 10 * 60;           # ten minutes
use constant LOCK_MAX_WAIT      => 15 * 60;           # fifteen minutes
use constant LOCK_POLL_INTERVAL => 30;

# Log levels
use constant DEBUG_OUTPUT => 1;

Bugzilla->usage_mode(USAGE_MODE_CMDLINE);
getopt
  't|test'            => \my $test,
  'q|quiet'           => \my $quiet,
  'd|debug'           => \my $debug,
  's|snapshot-date=s' => \my $snapshot_date,
  'w|lock-wait=i'     => \my $lock_wait,
  'n|no-cache=s'      => \my @no_cache;

$lock_wait //= LOCK_MAX_WAIT;

# Identifies this run in the lock table and in staging table names
my $run_id = time() . "_$$";

# Create a hash for faster checking later
my %no_cache = map { $_ => 1 } @no_cache;

# Sanity checks
Bugzilla->params->{bmo_etl_enabled} || die "BMO ETL not enabled.\n";

my $base_url = Bugzilla->params->{bmo_etl_base_url};
$base_url || die "Invalid BigQuery base URL.\n";

my $project_id = Bugzilla->params->{bmo_etl_project_id};
$project_id || die "Invalid BigQuery product ID.\n";

my $dataset_id = Bugzilla->params->{bmo_etl_dataset_id};
$dataset_id || die "Invalid BigQuery dataset ID.\n";

# The date is used in BigQuery SQL statements, so make sure it is sane.
# Checked before taking the lock so a bad value does not leave it behind.
if ($snapshot_date && $snapshot_date !~ /^\d{4}-\d{2}-\d{2}$/) {
  die "Invalid snapshot date '$snapshot_date', expected YYYY-MM-DD.\n";
}

# Check to make sure another instance is not currently running
check_and_set_lock();

# Use dedicated replica1
my $dbh = Bugzilla->switch_to_replica1_db;

my $ua = LWP::UserAgent::Determined->new(
  agent                 => 'Bugzilla',
  keep_alive            => 10,
  requests_redirectable => [qw(GET HEAD DELETE PUT)],
);
$ua->timing('1,2,4,8,16,32');
$ua->timeout(300); # five minutes
if (my $proxy = Bugzilla->params->{proxy_url}) {
  $ua->proxy(['https', 'http'], $proxy);
}

# This date will be added to each object as it is being sent
if (!$snapshot_date) {
  $snapshot_date = $dbh->selectrow_array(
    'SELECT ' . $dbh->sql_date_format('LOCALTIMESTAMP(0)', '%Y-%m-%d'));
}

# Excluded bugs: List of bug ids that we should not send data for to ETL (i.e. Legal, etc.)
our %excluded_bugs = ();

# Bugs that are private to one or more groups
our %private_bugs = ();

# Real table name => staging table name, column names, and rows sent
our %staging_tables = ();
our %table_columns  = ();
our %sent_counts    = ();

# Set by the signal handlers below. Checked before each batch is sent, since
# the die from a signal can be swallowed by an inner try block.
our $abort_reason;

# Kubernetes sends SIGTERM before killing the pod. If the process is killed
# outright (SIGKILL), the staging tables expire on their own and the real
# tables are untouched.
$SIG{TERM} = sub {
  $abort_reason = "Received SIGTERM, aborting export\n";
  die $abort_reason;
};
$SIG{INT} = sub {
  $abort_reason = "Received SIGINT, aborting export\n";
  die $abort_reason;
};

# Rows are streamed into staging tables and only copied into the real tables
# by publish_snapshot(), in a single transaction. If anything fails before
# then, the real tables never see any data for this snapshot date.
my $already_exported;
try {
  # Staging tables left by a run that died are no longer needed
  drop_orphaned_staging_tables();

  # In order to avoid entering duplicate data, we will first query BigQuery
  # to make sure other entries with this date are not already present. This
  # is not an error, since a retry after a run that published and then died
  # should simply finish.
  if (snapshot_exists()) {
    $already_exported = 1;
    return;
  }

  create_staging_tables();

  # Process each table to be sent to ETL
  process_bugs();
  process_attachments();
  process_flags();
  process_flag_activity();
  process_tracking_flags();
  process_keywords();
  process_see_also();
  process_users();

  process_two_columns(
    'bug_mentors', 'bug_mentors',
    ['bug_id', 'user_id'],
    ['bug_id', 'user_id']
  );
  process_two_columns(
    'dependencies', 'bug_dependencies',
    ['blocked', 'dependson'],
    ['bug_id',  'depends_on_id']
  );
  process_two_columns(
    'regressions', 'bug_regressions',
    ['regresses', 'regressed_by'],
    ['bug_id',    'regresses_id']
  );
  process_two_columns(
    'duplicates', 'bug_duplicates',
    ['dupe',   'dupe_of'],
    ['bug_id', 'duplicate_of_id']
  );

  publish_snapshot();
}
catch {
  drop_staging_tables();
  delete_lock();
  die $_;
};

if ($already_exported) {
  logger("Snapshot date $snapshot_date was already exported. Nothing to do.");
}

# If we are done, remove the staging tables and the lock
drop_staging_tables();
delete_lock();

### Functions

sub process_bugs {
  my $table_name  = 'bugs';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name");

  my $sth = $dbh->prepare(
    'SELECT bug_id, delta_ts FROM bugs ORDER BY bug_id LIMIT ? OFFSET ?');

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($id, $mod_time) = @{$row};

      logger("Processing id $id with mod_time of $mod_time.");

      # First check to see if we have a cached version with the same modification date
      my $data = get_cache($id, $table_name, $mod_time);

      if (!$data) {
        logger("$table_name id $id with time $mod_time not found in cache.",
          DEBUG_OUTPUT);

        my $obj = Bugzilla::Bug->new($id);

        if (!$obj) {
          logger("Object $id not loaded from database or no longer exists");
          next;
        }

        logger("Object $id loaded from database", DEBUG_OUTPUT);

        my $bug_is_private = scalar @{$obj->groups_in};

        if (any { $obj->product eq $_ } EXCLUDE_PRODUCTS) {
          $excluded_bugs{$obj->id} = 1;
          $total_count++;
          next;
        }

        $private_bugs{$obj->id} = 1 if $bug_is_private;

        # Standard non-sensitive fields
        $data = {
          id             => $obj->id,
          status         => $obj->bug_status,
          type           => $obj->bug_type,
          component      => $obj->component,
          creation_ts    => $obj->creation_ts,
          updated_ts     => $obj->delta_ts,
          op_sys         => $obj->op_sys,
          product        => $obj->product,
          platform       => $obj->rep_platform,
          reporter_id    => $obj->reporter->id,
          version        => $obj->version,
          team_name      => $obj->component_obj->team_name,
          classification => $obj->classification,
          comment_count  => $obj->comment_count,
          vote_count     => $obj->votes,
        };

        # Fields that require custom values based on criteria
        $data->{assignee_id}
          = $obj->assigned_to->login ne 'nobody@mozilla.org'
          ? $obj->assigned_to->id
          : undef;
        $data->{url}
          = (!$bug_is_private && $obj->bug_file_loc) ? $obj->bug_file_loc : undef;
        $data->{severity} = $obj->bug_severity ne '--' ? $obj->bug_severity : undef;
        $data->{crash_signature}
          = (!$bug_is_private && $obj->cf_crash_signature)
          ? $obj->cf_crash_signature
          : undef;
        $data->{priority}   = $obj->priority ne '--' ? $obj->priority   : undef;
        $data->{resolution} = $obj->resolution       ? $obj->resolution : undef;
        $data->{summary}    = !$bug_is_private       ? $obj->short_desc : undef;
        $data->{whiteboard}
          = (!$bug_is_private && $obj->status_whiteboard)
          ? $obj->status_whiteboard
          : undef;
        $data->{milestone}
          = $obj->target_milestone ne '---' ? $obj->target_milestone : undef;
        $data->{is_public} = $bug_is_private ? true : false;
        $data->{cc_count}  = scalar @{$obj->cc || []};

        # If more than one group, then pick the one with the least of amount of members
        if (!$bug_is_private) {
          $data->{group} = undef;
        }
        elsif (scalar @{$obj->groups_in} == 1) {
          my $groups = $obj->groups_in;
          $data->{group} = $groups->[0]->name;
        }
        else {
          $data->{group} = get_multi_group_value($obj);
        }

        # Store a copy of the data for use in later executions
        store_cache($obj->id, $table_name, $obj->delta_ts, $data);
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_attachments {
  my $table_name  = 'attachments';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth
    = $dbh->prepare(
    'SELECT attach_id, modification_time FROM attachments ORDER BY attach_id LIMIT ? OFFSET ?'
    );

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($id, $mod_time) = @{$row};

      logger("Processing id $id with mod_time of $mod_time.");

      # First check to see if we have a cached version with the same modification date
      my $data = get_cache($id, $table_name, $mod_time);

      if (!$data) {
        logger("$table_name id $id with time $mod_time not found in cache.",
          DEBUG_OUTPUT);

        my $obj = Bugzilla::Attachment->new($id);

        if (!$obj) {
          logger("Object $id not loaded from database or no longer exists");
          next;
        }

        logger("Object $id loaded from database", DEBUG_OUTPUT);

        if ($excluded_bugs{$obj->bug_id}) {
          $total_count++;
          next;
        }

        # Standard non-sensitive fields
        $data = {
          id           => $obj->id,
          bug_id       => $obj->bug_id,
          creation_ts  => $obj->attached,
          content_type => $obj->contenttype,
          updated_ts   => $obj->modification_time,
          submitter_id => $obj->attacher->id,
          is_obsolete  => ($obj->isobsolete ? true : false),
        };

        # Fields that require custom values based on criteria
        my $bug_is_private = exists $private_bugs{$obj->bug_id};
        $data->{description} = !$bug_is_private ? $obj->description : undef;
        $data->{filename}    = !$bug_is_private ? $obj->filename    : undef;

        # Store a new copy of the data for use later
        store_cache($obj->id, $table_name, $obj->modification_time, $data);
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_flags {
  my $table_name  = 'flags';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth = $dbh->prepare(
    'SELECT id, modification_date FROM flags ORDER BY id LIMIT ? OFFSET ?');

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($id, $mod_time) = @{$row};

      logger("Processing id $id with mod_time of $mod_time.");

      # First check to see if we have a cached version with the same modification date
      my $data = get_cache($id, $table_name, $mod_time);

      if (!$data) {
        logger("$table_name id $id with time $mod_time not found in cache.",
          DEBUG_OUTPUT);

        my $obj = Bugzilla::Flag->new($id);

        if (!$obj) {
          logger("Object $id not loaded from database or no longer exists");
          next;
        }

        logger("Object $id loaded from database", DEBUG_OUTPUT);

        if ($excluded_bugs{$obj->bug_id}) {
          $total_count++;
          next;
        }

        $data = {
          id            => $obj->id,
          attachment_id => $obj->attach_id || undef,
          bug_id        => $obj->bug_id,
          creation_ts   => $obj->creation_date,
          updated_ts    => $obj->modification_date,
          requestee_id  => $obj->requestee_id,
          setter_id     => $obj->setter_id,
          name          => $obj->type->name,
          value         => $obj->status,
        };

        # Store a new copy of the data for use later
        store_cache($obj->id, $table_name, $obj->modification_date, $data);
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

# Process flags that were removed today using the flag_activity table
# These entries will also go into the flags table in BigQuery.
sub process_flag_activity {
  my $table_name  = 'flag_activity';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth
    = $dbh->prepare(
    'SELECT id, flag_when FROM flag_activity WHERE status = \'X\' AND flag_when LIKE \''
      . $snapshot_date
      . ' %\' ORDER BY id LIMIT ? OFFSET ?');

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($id, $mod_time) = @{$row};

      logger("Processing id $id with mod_time of $mod_time.");

      # First check to see if we have a cached version with the same modification date
      my $data = get_cache($id, $table_name, $mod_time);

      if (!$data) {
        logger("$table_name id $id with time $mod_time not found in cache.",
          DEBUG_OUTPUT);

        my $obj = Bugzilla::FlagActivity->new($id);

        if (!$obj) {
          logger("Object $id not loaded from database or no longer exists");
          next;
        }

        logger("Object $id loaded from database", DEBUG_OUTPUT);

        if ($excluded_bugs{$obj->bug_id}) {
          $total_count++;
          next;
        }

        $data = {
          attachment_id => $obj->attachment_id || undef,
          bug_id        => $obj->bug_id,
          creation_ts   => $obj->flag_when,
          updated_ts    => $obj->flag_when,
          requestee_id  => $obj->requestee_id,
          setter_id     => $obj->setter_id,
          name          => $obj->type->name,
          value         => $obj->status,
        };

        # Store a new copy of the data for use later
        store_cache($obj->id, $table_name, $obj->flag_when, $data);
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data('flags', \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_tracking_flags {
  my $table_name  = 'tracking_flags';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth = $dbh->prepare(
    'SELECT tracking_flags_bugs.id, tracking_flags.name, tracking_flags_bugs.bug_id, tracking_flags_bugs.value
      FROM tracking_flags_bugs
           JOIN tracking_flags
           ON tracking_flags_bugs.tracking_flag_id = tracking_flags.id
      ORDER BY tracking_flags_bugs.id LIMIT ? OFFSET ?'
  );

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($id, $name, $bug_id, $value) = @{$row};

      if ($excluded_bugs{$bug_id}) {
        $total_count++;
        next;
      }

      # Standard fields
      my $data = {id => $id, bug_id => $bug_id};

      # Fields that require custom values based on other criteria
      if (exists $private_bugs{$bug_id}) {
        $data->{name}  = undef;
        $data->{value} = undef;
      }
      else {
        $data->{name}  = $name;
        $data->{value} = $value;
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_keywords {
  my $table_name  = 'keywords';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth = $dbh->prepare(
    'SELECT bug_id, keyworddefs.name
        FROM keywords
              JOIN keyworddefs
              ON keywords.keywordid = keyworddefs.id
        ORDER BY bug_id LIMIT ? OFFSET ?'
  );

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($bug_id, $keyword) = @{$row};

      if ($excluded_bugs{$bug_id}) {
        $total_count++;
        next;
      }

      # Standard fields
      my $data = {bug_id => $bug_id};

      # Fields that require custom values based on other criteria
      $data->{keyword} = !exists $private_bugs{$bug_id} ? $keyword : undef;

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger(
      "total count: $total_count, count: $total_count, last offset: $last_offset",
      DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_see_also {
  my $table_name  = 'see_also';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth
    = $dbh->prepare(
    'SELECT bug_id, value, class FROM bug_see_also ORDER BY bug_id LIMIT ? OFFSET ?'
    );

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($bug_id, $value, $class) = @{$row};

      if ($excluded_bugs{$bug_id}) {
        $total_count++;
        next;
      }

      # Standard fields
      my $data = {bug_id => $bug_id,};

      # Fields that require custom values based on other criteria
      if ($private_bugs{$bug_id}) {
        $data->{url} = undef;
      }
      elsif ($class =~ /::Local/) {
        $data->{url} = Bugzilla->localconfig->urlbase . 'show_bug.cgi?id=' . $value;
      }
      else {
        $data->{url} = $value;
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_users {
  my $table_name  = 'users';
  my $total_count = 0;
  my $last_offset = 0;

  logger("Processing $table_name.");

  my $sth
    = $dbh->prepare(
    'SELECT userid, modification_ts FROM profiles ORDER BY userid LIMIT ? OFFSET ?'
    );

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($id, $mod_time) = @{$row};

      logger("Processing id $id with mod_time of $mod_time.");

      # Set the mod time to an arbitrary value for caching purposes if its
      # real mod time is not yet been set to a real value.
      $mod_time = '1970-01-01 12:00:00' if !$mod_time;

      # First check to see if we have a cached version with the same modification date
      my $data = get_cache($id, $table_name, $mod_time);

      if (!$data) {
        logger("$table_name id $id with time $mod_time not found in cache.",
          DEBUG_OUTPUT);

        my $obj = Bugzilla::User->new($id);

        if (!$obj) {
          logger("Object $id not loaded from database or no longer exists");
          next;
        }

        logger("Object $id loaded from database", DEBUG_OUTPUT);

        # Standard fields
        $data = {
          id        => $obj->id,
          last_seen =>
            ($obj->last_seen_date ? $obj->last_seen_date . ' 00:00:00' : undef),
          email  => $obj->email,
          is_new => ($obj->is_new ? true : false),
        };

        # Fields that require custom values based on criteria
        $data->{nick} = $obj->nick ? $obj->nick : undef;
        $data->{name} = $obj->name ? $obj->name : undef;
        $data->{is_staff}
          = $obj->in_group('mozilla-employee-confidential') ? true : false;
        $data->{is_trusted} = $obj->in_group('editbugs') ? true             : false;
        $data->{ldap_email} = $obj->ldap_email           ? $obj->ldap_email : undef;

        # Store a new copy of the data for use later
        store_cache($obj->id, $table_name, $obj->modification_ts, $data);
      }

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($table_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub process_two_columns {
  my ($table_name, $bq_name, $column_names, $data_names) = @_;
  my $total_count    = 0;
  my $last_offset    = 0;
  my $columns_string = join ', ', @{$column_names};
  my $order_by       = $column_names->[0];

  logger("Processing $table_name.");

  my $sth = $dbh->prepare(
    "SELECT $columns_string FROM $table_name ORDER BY $order_by LIMIT ? OFFSET ?");

  $sth->execute(API_BLOCK_COUNT, $last_offset);

  while (my @rows = @{$sth->fetchall_arrayref() || []}) {
    my @results;

    foreach my $row (@rows) {
      my ($value1, $value2) = @{$row};

      if ($excluded_bugs{$value1}) {
        $total_count++;
        next;
      }

      logger("Processing values $value1, $value2 for $table_name.");

      my $data = {$data_names->[0] => $value1, $data_names->[1] => $value2,};

      push @results, $data;

      $total_count++;
    }

    # Send a batch of data and then run query for the next batch of rows
    logger("total count: $total_count, last offset: $last_offset", DEBUG_OUTPUT);

    # Send the rows to the server
    send_data($bq_name, \@results, $total_count);

    $last_offset += API_BLOCK_COUNT;
    $sth->execute(API_BLOCK_COUNT, $last_offset);
  }
}

sub get_cache {
  my ($id, $table, $timestamp) = @_;

  if ($no_cache{$table}) {
    logger("Retrieving cached data is disabled for $table.");
    return undef;
  }

  logger("Retreiving data from $table for $id with time $timestamp.",
    DEBUG_OUTPUT);

  try {
    # Retrieve compressed JSON from cache table if it exists
    my $gzipped_data = $dbh->selectrow_array(
      'SELECT data FROM bmo_etl_cache WHERE id = ? AND table_name = ? AND snapshot_date = ?',
      undef, $id, $table, $timestamp
    );
    return undef if !$gzipped_data;

    # First uncompress the JSON and then decode it back to Perl data
    my $data;
    unless (gunzip \$gzipped_data => \$data) {
      die "gunzip failed: $GunzipError\n";
    }
    return decode_json($data);
  }
  catch {
    # Log the failure and return undef
    WARN("ERROR: Unable to retrieve cached data from database: $_");
    return undef;
  }
}

sub store_cache {
  my ($id, $table, $timestamp, $data) = @_;

  if ($no_cache{$table}) {
    logger("Storing cached data is disabled for $table.");
    return undef;
  }

  logger("Storing data into $table for $id with time $timestamp.", DEBUG_OUTPUT);

  # Encode the perl data into JSON
  $data = encode_json($data);

  # Compress the JSON to save space in the DB
  my $gzipped_data;
  unless (gzip \$data => \$gzipped_data) {
    die "gzip failed: $GzipError\n";
  }

  # We need to use the main DB for write operations
  my $main_dbh = Bugzilla->dbh_main;

  try {
    # Clean out outdated JSON
    $main_dbh->do('DELETE FROM bmo_etl_cache WHERE id = ? AND table_name = ?',
      undef, $id, $table);

    # Enter new cached JSON
    $main_dbh->do(
      'INSERT INTO bmo_etl_cache (id, table_name, snapshot_date, data) VALUES (?, ?, ?, ?)',
      undef, $id, $table, $timestamp, $gzipped_data
    );
  }
  catch {
    # Log the failure
    WARN("ERROR: Unable to store cache data in database: $_");
  }
}

sub send_data {
  my ($table, $all_rows, $current_count) = @_;

  logger(
    'Sending ' . scalar @{$all_rows} . " rows to table $table using BigQuery API");

  # Add the same snapshot date to every row sent
  foreach my $row (@{$all_rows}) {
    $row->{snapshot_date} = $snapshot_date;
  }

  if ($test) {
    my $big_query = {rows => [map { +{json => $_} } @{$all_rows}]};

    my $filename
      = bz_locations()->{'datadir'} . '/'
      . $snapshot_date . '-'
      . $table . '-'
      . $current_count . '.json';

    logger("Writing data to $filename.");

    my $fh = path($filename)->open('>>');
    print $fh encode_json($big_query) . "\n";
    unless (close $fh) {
      die "Could not close $filename: $!\n";
    }

    return;
  }

  # Stop sending if a signal was received, even if an inner try block
  # swallowed the die from the signal handler.
  die $abort_reason if $abort_reason;

  my $staging_table = $staging_tables{$table}
    || die "No staging table for $table\n";

  # Give each row a key that is unique within this run. The HTTP client
  # resends the whole batch if a request fails after BigQuery accepted it, so
  # the key lets publish_snapshot() drop those duplicates without merging
  # rows that are legitimately identical (cleared flags have no id). It is
  # also sent as insertId so BigQuery drops most duplicates on its own.
  my $row_num = $sent_counts{$table};
  my @keyed_rows;
  foreach my $row (@{$all_rows}) {
    my $key = "$table-" . $row_num++;
    push @keyed_rows, {insertId => $key, json => {%{$row}, STAGING_ROW_KEY, $key}};
  }

  my $content = encode_json({rows => \@keyed_rows});
  my $response
    = bq_request('POST', "datasets/$dataset_id/tables/$staging_table/insertAll",
    $content);

  my $result = decode_json($response->content);

  if (!$response->is_success
    || (exists $result->{insertErrors} && @{$result->{insertErrors}}))
  {
    die "Google Big Query insert failure:\nRequest:\n"
      . $content
      . "\n\nResponse:\n"
      . $response->content . "\n";
  }

  $sent_counts{$table} += scalar @{$all_rows};

  refresh_lock();
}

sub _get_access_token {
  state $access_token;    # We should only need to get this once
  state $token_expiry;

  logger('Checking for acess token', DEBUG_OUTPUT);

  # If we already have a token and it has not expired yet, just return it
  if ($access_token && time < $token_expiry) {
    logger('Previous access token found', DEBUG_OUTPUT);
    return $access_token;
  }

# Google Kubernetes allows for the use of Workload Identity. This allows
# us to link two service accounts together and give special access for applications
# running under Kubernetes. We use the special access to get an OAuth2 access_token
# that can then be used for accessing the the Google API such as BigQuery.
  my $url
    = sprintf
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/%s/token',
    Bugzilla->params->{bmo_etl_service_account};

  my $http_headers = HTTP::Headers->new;
  $http_headers->header('Metadata-Flavor' => 'Google');

  my $request = HTTP::Request->new('GET', $url, $http_headers);

  my $res = $ua->request($request);

  if (!$res->is_success) {
    die 'Google access token failure: ' . $res->content . "\n";
  }

  my $result = decode_json($res->decoded_content);
  $access_token = $result->{access_token};
  $token_expiry = time + $result->{expires_in};

  logger('New access token returned', DEBUG_OUTPUT);

  return $access_token;
}

# Take the export lock. If another run holds it, wait for that run to
# finish. A lock that stops being refreshed belongs to a run that died
# (for example a pod that was killed), so it is removed and taken over.
sub check_and_set_lock {
  return if $test;    # No need if just dumping test files

  logger('Checking for previous lock or setting new one', DEBUG_OUTPUT);

  my $dbh_main = Bugzilla->dbh_main;
  my $waited   = 0;

  while (1) {
    my $stale
      = $dbh_main->do(
      'DELETE FROM bmo_etl_locked WHERE COALESCE(updated_ts, creation_ts) < '
        . $dbh_main->sql_date_math('NOW()', '-', LOCK_STALE_AFTER / 60, 'MINUTE'));
    if ($stale > 0) {
      logger('Removed stale lock left by a previous run that did not finish.');
    }

    # The unique index on name allows only one lock row, so if two runs get
    # here at the same time only one insert succeeds.
    my $inserted = $dbh_main->do(
      'INSERT IGNORE INTO bmo_etl_locked (value, creation_ts, updated_ts)
       VALUES (?, NOW(), NOW())', undef, $run_id
    );
    if ($inserted > 0) {
      logger("Set new lock for run $run_id.", DEBUG_OUTPUT);
      return;
    }

    # The lock may have been released since the insert. Waiting as usual
    # keeps this loop bounded if the insert keeps failing for another reason.
    my $owner = $dbh_main->selectrow_array('SELECT value FROM bmo_etl_locked')
      // 'unknown';

    if ($waited >= $lock_wait) {
      die "Another process ($owner) has set a lock. Exiting\n";
    }

    logger("Export run $owner holds the lock. Waiting.");
    sleep LOCK_POLL_INTERVAL;
    $waited += LOCK_POLL_INTERVAL;
  }
}

# Refresh the lock so other runs know this one is still alive. Dies if the
# lock was taken over, which means this run stalled for too long and must
# not publish. Pass a true value to skip the rate limit.
sub refresh_lock {
  my ($force) = @_;
  return if $test;

  state $last_refresh = 0;
  return if !$force && time() - $last_refresh < LOCK_REFRESH_EVERY;

  my $updated
    = Bugzilla->dbh_main->do(
    'UPDATE bmo_etl_locked SET updated_ts = NOW() WHERE value = ?',
    undef, $run_id);
  if ($updated < 1) {
    die "Lost the export lock to another run. Aborting\n";
  }

  $last_refresh = time();
}

# Delete this run's lock from bmo_etl_locked
sub delete_lock {
  return if $test;
  logger("Deleting lock in database.");
  Bugzilla->dbh_main->do('DELETE FROM bmo_etl_locked WHERE value = ?',
    undef, $run_id);
}

# Returns true if BigQuery already has data for this snapshot date
sub snapshot_exists {
  return 0 if $test;    # no need if just dumping test files

  logger("Checking for existing data for snapshot date $snapshot_date.");

  # Snapshots are published to all tables at once, so checking bugs is enough
  my $result
    = run_bq_query(
    "SELECT count(*) FROM `${project_id}.${dataset_id}.bugs` WHERE snapshot_date = '$snapshot_date';"
    );

  return $result->{rows}->[0]->{f}->[0]->{v} ? 1 : 0;
}

# Drop staging tables left behind by earlier runs that died. This run holds
# the lock, so no other run is using them.
sub drop_orphaned_staging_tables {
  return if $test;

  my @orphans;
  my $page_token = '';
  do {
    my $path = "datasets/$dataset_id/tables?maxResults=1000";
    $path .= "&pageToken=$page_token" if $page_token;

    my $response = bq_request('GET', $path);
    if (!$response->is_success) {
      die "Unable to list tables in $dataset_id: " . $response->content . "\n";
    }

    my $result = decode_json($response->content);
    push @orphans,
      grep { index($_, STAGING_PREFIX) == 0 }
      map { $_->{tableReference}->{tableId} } @{$result->{tables} || []};
    $page_token = $result->{nextPageToken};
  } while ($page_token);

  foreach my $staging_table (@orphans) {
    logger("Dropping orphaned staging table $staging_table.");
    my $response
      = bq_request('DELETE', "datasets/$dataset_id/tables/$staging_table");
    if (!$response->is_success && $response->code != 404) {
      die "Unable to drop staging table $staging_table: " . $response->content . "\n";
    }
  }
}

# Create an empty staging table for each real table, with the same schema.
# The run id keeps names unique, since streaming into a table that was just
# deleted and recreated with the same name can lose rows.
sub create_staging_tables {
  return if $test;

  my $expiration = (time() + STAGING_LIFETIME) * 1000;

  foreach my $table (BQ_TABLES) {
    my $response = bq_request('GET', "datasets/$dataset_id/tables/$table");
    if (!$response->is_success) {
      die "Unable to read schema for $table: " . $response->content . "\n";
    }
    my $schema = decode_json($response->content)->{schema};

    my $staging_table = STAGING_PREFIX . "${table}_$run_id";
    logger("Creating staging table $staging_table.");

    # Staging has one extra column holding the row key set in send_data()
    my $staging_schema = {fields =>
        [@{$schema->{fields}}, {name => STAGING_ROW_KEY, type => 'STRING'}]};

    $response = bq_request(
      'POST',
      "datasets/$dataset_id/tables",
      encode_json({
        tableReference => {
          projectId => $project_id,
          datasetId => $dataset_id,
          tableId   => $staging_table,
        },
        schema         => $staging_schema,
        expirationTime => "$expiration",
      })
    );
    if (!$response->is_success) {
      die "Unable to create staging table $staging_table: "
        . $response->content . "\n";
    }

    $staging_tables{$table} = $staging_table;
    $table_columns{$table}  = [map { $_->{name} } @{$schema->{fields}}];
    $sent_counts{$table}    = 0;
  }
}

# Copy every staging table into its real table in one transaction, so either
# the whole snapshot appears or none of it does.
sub publish_snapshot {
  return if $test;

  # Make sure every row that was sent is visible in staging before copying.
  # Streamed rows are normally queryable within a few seconds. Count row keys
  # rather than rows, since a retried insert can leave duplicates.
  foreach my $table (BQ_TABLES) {
    my $staging_table = $staging_tables{$table};
    my $count;
    foreach my $attempt (1 .. 6) {
      my $result = run_bq_query(
        "SELECT COUNT(DISTINCT " . STAGING_ROW_KEY . ") "
          . "FROM `${project_id}.${dataset_id}.${staging_table}`;");
      $count = $result->{rows}->[0]->{f}->[0]->{v} // 0;
      last if $count == $sent_counts{$table};
      logger("$staging_table has $count of $sent_counts{$table} rows, waiting.");
      sleep 10;
    }
    if ($count != $sent_counts{$table}) {
      die "Staging table $staging_table has $count rows "
        . "but $sent_counts{$table} were sent\n";
    }
  }

  logger("Publishing snapshot date $snapshot_date.");

  # snapshot_exists() ran when this run started, but a transaction submitted
  # by an earlier run can keep going in BigQuery after that run died and
  # commit later. So every insert also checks for the snapshot, and fails the
  # whole transaction if it is already there. bugs goes last, since the
  # check looks at bugs and must not see the rows this transaction adds.
  my $already_published
    = "IF(EXISTS(SELECT 1 FROM `${project_id}.${dataset_id}.bugs` "
    . "WHERE snapshot_date = '$snapshot_date'), "
    . "ERROR('Snapshot date $snapshot_date was already exported'), TRUE)";

  # Copy one row per row key, so rows sent twice by a retried insert are
  # only published once
  my $row_key = STAGING_ROW_KEY;
  my @statements;
  foreach my $table ((grep { $_ ne 'bugs' } BQ_TABLES), 'bugs') {
    my $columns = join ', ', map {"`$_`"} @{$table_columns{$table}};
    push @statements,
        "INSERT INTO `${project_id}.${dataset_id}.${table}` ($columns) "
      . "SELECT $columns FROM (SELECT *, ROW_NUMBER() OVER "
      . "(PARTITION BY `$row_key`) AS _etl_copy "
      . "FROM `${project_id}.${dataset_id}.$staging_tables{$table}`) "
      . "WHERE _etl_copy = 1 AND $already_published;";
  }

  # Make sure no other run has taken over before making the data visible
  refresh_lock(1);

  try {
    run_bq_query(join "\n", 'BEGIN TRANSACTION;',
      @statements, 'COMMIT TRANSACTION;');
    logger("Snapshot date $snapshot_date published.");
  }
  catch {
    my $error = $_;

    # The snapshot is there if the guard above fired, or if this run's
    # transaction committed but waiting for the result failed. Either way
    # it was published exactly once, so the run has nothing left to do.
    my $exists = try { snapshot_exists() } catch {0};
    die $error if !$exists;

    logger("Snapshot date $snapshot_date is already in BigQuery. Nothing to do.");
  };
}

# Drop any staging tables created by this run. Failures are only logged,
# since the tables expire on their own.
sub drop_staging_tables {
  foreach my $table (keys %staging_tables) {
    my $staging_table = delete $staging_tables{$table};
    logger("Dropping staging table $staging_table.");
    try {
      my $response
        = bq_request('DELETE', "datasets/$dataset_id/tables/$staging_table");
      if (!$response->is_success && $response->code != 404) {
        WARN(
          "ERROR: Unable to drop staging table $staging_table: " . $response->content);
      }
    }
    catch {
      WARN("ERROR: Unable to drop staging table $staging_table: $_");
    };
  }
}

# Run a SQL statement using the BigQuery jobs.query API and return the
# decoded response, waiting for long running jobs to finish.
sub run_bq_query {
  my ($sql) = @_;

  logger($sql, DEBUG_OUTPUT);

  my $response = bq_request('POST', 'queries',
    encode_json({query => $sql, useLegacySql => false, timeoutMs => 60000}));
  if (!$response->is_success) {
    die 'Google Big Query query failure: ' . $response->content . "\n";
  }

  my $result = decode_json($response->content);
  my $waited = 0;

  # The job keeps running in BigQuery after the request times out, so poll
  # for the result rather than giving up and leaving its outcome unknown.
  while (!$result->{jobComplete}) {
    if ($waited >= QUERY_MAX_WAIT) {
      die "Google Big Query query did not complete in time: $sql\n";
    }

    my $job      = $result->{jobReference};
    my $location = $job->{location} ? "&location=$job->{location}" : '';
    $response = bq_request('GET',
      "queries/$job->{jobId}?timeoutMs=60000&maxResults=0$location");
    if (!$response->is_success) {
      die 'Google Big Query query failure: ' . $response->content . "\n";
    }

    $result = decode_json($response->content);
    $waited += 60;

    refresh_lock();
  }

  logger(encode_json($result), DEBUG_OUTPUT);

  return $result;
}

# Send a request to the BigQuery API. The path is relative to the project.
sub bq_request {
  my ($method, $path, $content) = @_;

  my $http_headers = HTTP::Headers->new;

  # Do not attempt to get access token if running in test environment
  if ($base_url !~ /^http:\/\/[^\/]+:9050/) {
    my $access_token = _get_access_token();
    $http_headers->header(Authorization => 'Bearer ' . $access_token);
  }

  my $url = "$base_url/projects/$project_id/$path";
  logger("$method $url", DEBUG_OUTPUT);

  my $request = HTTP::Request->new($method, $url, $http_headers);
  if (defined $content) {
    $request->header('Content-Type' => 'application/json');
    $request->content($content);
  }

  my $response = $ua->request($request);
  logger($response->content, DEBUG_OUTPUT);

  return $response;
}

sub get_multi_group_value {
  my ($bug) = @_;

  logger('Checking for multi group values.', DEBUG_OUTPUT);

  my $smallest_group_name  = undef;
  my $smallest_group_count = 0;

  foreach my $group (@{$bug->groups_in}) {
    my $user_count  = 0;
    my $member_data = $group->members_complete;
    foreach my $type (keys %{$member_data}) {
      $user_count += scalar @{$member_data->{$type}};
    }
    if ($user_count < $smallest_group_count) {
      $smallest_group_count = $user_count;
      $smallest_group_name  = $group->name;
    }
  }

  logger("Smallest group members: $smallest_group_name") if $smallest_group_name;

  return $smallest_group_name;
}

sub logger {
  my ($message, $level) = @_;

  # Skip if -q or --quiet was specified
  return if $quiet;

  # Skip if --debug was not specified and this is a DEBUG level entry
  return if (defined $level && $level == DEBUG_OUTPUT && !$debug);

  # Otherwise just print
  print time() . ": $message\n";
}

1;
