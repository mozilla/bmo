#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 2085398 - Backfill flag_activity from bugs_activity.
#
# Parses historical flagtypes.name rows in bugs_activity and inserts the
# missing records into flag_activity. Safe to run while dual-write is active;
# skips entries already present in flag_activity.
#
# Backfilled rows get flag_id 0: the flag can't be recovered reliably from
# bugs_activity, and bug history and bugmail skip the previous-state lookup
# for flag_id 0.
#
# Works through bugs in bug_id batches, one transaction per batch.
#
# Usage: perl scripts/flag_activity_backfill.pl [--dry-run]

use 5.10.1;
use strict;
use warnings;

use File::Basename        qw(dirname);
use File::Spec::Functions qw(catdir rel2abs);

BEGIN {
  require lib;
  my $dir = rel2abs(catdir(dirname(__FILE__), '..'));
  lib->import($dir, catdir($dir, 'lib'), catdir($dir, qw(local lib perl5)));
}

use Bugzilla;
use Bugzilla::Constants;

use constant BATCH_SIZE => 1000;

Bugzilla->usage_mode(USAGE_MODE_CMDLINE);

my $dry_run = grep { $_ eq '--dry-run' } @ARGV;
print "DRY RUN — no data will be written.\n" if $dry_run;

my $dbh = Bugzilla->dbh;

# Get the fieldid for 'flagtypes.name' in bugs_activity.
my ($fieldid)
  = $dbh->selectrow_array(
  "SELECT id FROM fielddefs WHERE name = 'flagtypes.name'");
die "Could not find fieldid for 'flagtypes.name' in fielddefs\n"
  unless $fieldid;

# Build a cache of flag type name -> id.
my %type_id_cache;
my $types
  = $dbh->selectall_arrayref("SELECT id, name FROM flagtypes", {Slice => {}});
$type_id_cache{$_->{name}} = $_->{id} for @$types;

# login_name -> userid, filled as requestees are seen.
my %user_id_cache;

sub requestee_id {
  my ($email) = @_;
  return undef unless $email;
  $user_id_cache{$email}
    //= $dbh->selectrow_array("SELECT userid FROM profiles WHERE login_name = ?",
    undef, $email) // 0;
  return $user_id_cache{$email} || undef;
}

# Parse a single flag string like "review?(user@example.com)" or "review+".
# Returns (type_name, status, requestee_email_or_undef) or empty list.
sub parse_flag_str {
  my ($str) = @_;
  $str =~ s/^\s+|\s+$//g;
  return unless $str =~ /^(.+?)([?+\-])(?:\(([^)]+)\))?$/;
  return ($1, $2, $3);
}

# Duplicate keys. The full key includes the requestee, so asking two people
# for the same flag in one change backfills both rows. When the requestee
# can't be resolved (account renamed or deleted since), fall back to the key
# without it so dual-written rows are not inserted twice.
sub short_key {
  my ($bug_id, $when, $type_id, $status, $attach_id) = @_;
  return join(':', $bug_id, $when, $type_id, $status, $attach_id // '');
}

sub full_key {
  my ($requestee_id, @short) = @_;
  return join(':', short_key(@short), $requestee_id // '');
}

my ($max_bug_id)
  = $dbh->selectrow_array(
  "SELECT MAX(bug_id) FROM bugs_activity WHERE fieldid = ?",
  undef, $fieldid);
$max_bug_id //= 0;

my ($total, $inserted, $skipped, $unknown_type, $unknown_user)
  = (0, 0, 0, 0, 0);

# Flag states to record for one bugs_activity row:
# - Each item in 'added' records its new state directly.
# - Items in 'removed' with no counterpart type in 'added' were deleted.
sub flag_changes {
  my ($row) = @_;
  my (@changes, %added_types);

  for my $item (split /,\s*/, $row->{added} // '') {
    my ($name, $status, $requestee_email) = parse_flag_str($item) or next;
    $added_types{$name} = 1;
    push @changes,
      {name => $name, status => $status, requestee_email => $requestee_email};
  }

  for my $item (split /,\s*/, $row->{removed} // '') {
    my ($name, $status, $requestee_email) = parse_flag_str($item) or next;

    # Only record 'X' if this type does not appear in added (truly deleted).
    next if $added_types{$name};
    push @changes,
      {name => $name, status => 'X', requestee_email => $requestee_email};
  }

  return @changes;
}

sub backfill_batch {
  my ($from, $to) = @_;

  my (%existing, %existing_short);
  my $existing_rows = $dbh->selectall_arrayref(
    "SELECT bug_id, flag_when, type_id, status, attachment_id, requestee_id
       FROM flag_activity
      WHERE bug_id BETWEEN ? AND ?", undef, $from, $to
  );
  for my $row (@$existing_rows) {
    my @short = @$row[0 .. 4];
    $existing{full_key($row->[5], @short)} = 1;
    $existing_short{short_key(@short)} = 1;
  }

  my $rows = $dbh->selectall_arrayref(
    "SELECT bug_id, who, bug_when, removed, added, attach_id
       FROM bugs_activity
      WHERE fieldid = ? AND bug_id BETWEEN ? AND ?
      ORDER BY bug_when, id", {Slice => {}}, $fieldid, $from, $to
  );
  return unless @$rows;

  $dbh->bz_start_transaction() unless $dry_run;

  for my $row (@$rows) {
    $total++;

    for my $change (flag_changes($row)) {
      my $type_id = $type_id_cache{$change->{name}};
      unless ($type_id) {
        $unknown_type++;
        next;
      }

      my $requestee_id = requestee_id($change->{requestee_email});
      $unknown_user++ if $change->{requestee_email} && !$requestee_id;

      my @short = (
        $row->{bug_id},    $row->{bug_when}, $type_id,
        $change->{status}, $row->{attach_id}
      );
      my $key = full_key($requestee_id, @short);

      # Skip if already in flag_activity.
      if ($existing{$key} || (!$requestee_id && $existing_short{short_key(@short)})) {
        $skipped++;
        next;
      }

      unless ($dry_run) {
        $dbh->do(
          "INSERT INTO flag_activity
             (flag_when, type_id, flag_id, setter_id, requestee_id,
              bug_id, attachment_id, status)
           VALUES (?, ?, 0, ?, ?, ?, ?, ?)", undef, $row->{bug_when}, $type_id,
          $row->{who}, $requestee_id, $row->{bug_id}, $row->{attach_id}, $change->{status}
        );
      }

      $existing{$key} = 1;
      $existing_short{short_key(@short)} = 1;
      $inserted++;
    }
  }

  $dbh->bz_commit_transaction() unless $dry_run;

  printf
    "  Bugs %d-%d done, %d bugs_activity rows processed (inserted: %d, skipped: %d)\n",
    $from, $to, $total, $inserted, $skipped;
}

print "Processing bugs_activity rows...\n";

my $from = 1;
while ($from <= $max_bug_id) {
  backfill_batch($from, $from + BATCH_SIZE - 1);
  $from += BATCH_SIZE;
}

print "\nDone.\n";
printf "  bugs_activity rows processed     : %d\n", $total;
printf "  flag_activity rows inserted      : %d\n", $inserted;
printf "  already present (skipped)        : %d\n", $skipped;
printf "  unknown flag type (skipped)      : %d\n", $unknown_type;
printf "  unknown requestee (NULL inserted): %d\n", $unknown_user;
