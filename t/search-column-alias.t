#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bugzilla::Search::_sql_select interpolates each display column name,
# unquoted, as the SQL alias ("<expr> AS <alias>"). Column names come from
# fielddefs, and the TrackingFlags admin used to accept any cf_ name, so a
# stored name such as "cf_x FROM profiles -- " became SQL. This pins both
# halves of the fix: Search refuses a non-identifier alias before any SQL is
# built, and TrackingFlags refuses to store such a name in the first place.

use 5.10.1;
use strict;
use warnings;
use lib qw( . lib local/lib/perl5 );

use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;
use Bugzilla;
use Bugzilla::Constants;
BEGIN { Bugzilla->extensions }
use Test2::V0;
use ok 'Bugzilla::Search';
use ok 'Bugzilla::Extension::TrackingFlags::Flag';

my $malicious = 'cf_x FROM profiles -- ';

# Drive _sql_select with a fixed column list so no fielddefs rows are needed.
# Scoped so the database-backed section below runs the real Search methods.
{
  my @columns;
  my $search_mock = mock 'Bugzilla::Search' => (
    override => [
      _display_columns => sub {@columns},
      COLUMNS          => sub {
        return {map { $_ => {name => "expr_for_$_"} } @columns};
      },
    ],
  );
  my $search = bless {}, 'Bugzilla::Search';

  subtest 'Search rejects unsafe aliases' => sub {
    @columns = ($malicious);
    like(
      dies { $search->_sql_select },
      qr/as a field name/,
      'stored name with SQL in it is refused'
    );

    @columns = ('cf_a;b');
    like(
      dies { $search->_sql_select },
      qr/as a field name/,
      'punctuation is refused'
    );
  };

  subtest 'Search keeps valid aliases working' => sub {
    @columns = ('bug_id', 'cf_tracking_firefox123', 'assigned_to.login_name');
    my @sql;
    ok(lives { @sql = $search->_sql_select }, 'valid columns are accepted');
    is(
      \@sql,
      [
        'expr_for_bug_id AS bug_id',
        'expr_for_cf_tracking_firefox123 AS cf_tracking_firefox123',
        'expr_for_assigned_to.login_name AS assigned_to_login_name',
      ],
      'dotted column is normalized to an underscore alias'
    );
  };
}

subtest 'TrackingFlags refuses unsafe names' => sub {
  my $class = 'Bugzilla::Extension::TrackingFlags::Flag';
  for my $name ($malicious, 'cf_a-b', 'cf_caf' . chr 0xe9) {
    like(
      dies { $class->_check_name($name) },
      qr/not a valid name for a field/,
      "name '$name' is refused"
    );
  }
  is($class->_check_name(' cf_tracking_firefox123 '),
    'cf_tracking_firefox123', 'normal name is accepted and trimmed');
};

# The cases above mock COLUMNS, so they never run the TrackingFlags hooks.
# The cases below go through Search->data against the in-memory database,
# with an unsafe flag stored the way a pre-fix install could have it.

my $dbh = Bugzilla->dbh;

# The audit's payload: a scalar subquery smuggled in as the SELECT alias.
my $legacy = 'cf_probe,(SELECT(api_key)FROM(user_api_keys)WHERE(id=5))x';
my $marker = qr/user_api_keys/;

# Raw inserts, because _check_name now refuses unsafe names; this is how a
# row stored before the fix looks.
sub insert_flag {
  my ($name) = @_;
  $dbh->do(
    'INSERT INTO fielddefs (name, description, sortkey, type, custom, obsolete, buglist)
     VALUES (?, ?, 0, ?, 1, 0, 1)', undef, $name, $name, FIELD_TYPE_EXTENSION
  );
  my $field_id = $dbh->bz_last_key('fielddefs', 'id');
  $dbh->do(
    "INSERT INTO tracking_flags (field_id, name, description, type)
     VALUES (?, ?, ?, 'tracking')", undef, $field_id, $name, $name
  );
}

# Search and TrackingFlags cache fields, flags and the column/join maps per
# request, and data() rewrites cached column expressions on the >30 path.
sub reset_caches {
  delete @{Bugzilla->request_cache}
    {qw(fields tracking_flags tracking_flags_names search_columns column_joins)};
}

my $product   = Bugzilla::Product->new({name => 'Firefox'});
my $component = $product->components->[0];
my $nobody    = Bugzilla::User->new({name => 'nobody@mozilla.org'});
$dbh->do(
  "INSERT INTO bugs (assigned_to, reporter, product_id, component_id, version,
     bug_severity, bug_status, bug_type, priority, op_sys, rep_platform,
     short_desc, creation_ts, delta_ts, everconfirmed)
   VALUES (?, ?, ?, ?, 'unspecified', 'normal', 'NEW', 'defect', 'P1',
     'Unspecified', 'Unspecified', 'canary', ?, ?, 1)", undef, $nobody->id,
  $nobody->id, $product->id, $component->id, ('2026-01-01 00:00:00') x 2
);
my $bug_id = $dbh->bz_last_key('bugs', 'bug_id');

my @safe = map { sprintf 'cf_tracking_safe_%02d', $_ } 1 .. 31;
insert_flag($_) for @safe, $legacy;

# Record every statement Search hands to the database.
my @executed;
my $exec_mock = mock 'Bugzilla::Search' => (
  around => [
    _sql_execute => sub {
      my ($orig, $self, $sql, @rest) = @_;
      push @executed, $sql;
      return $self->$orig($sql, @rest);
    },
  ],
);

sub run_search {
  my (@fields) = @_;
  reset_caches();
  @executed = ();
  return Bugzilla::Search->new(
    fields => ['bug_id', @fields],
    params => {bug_id => $bug_id, bug_id_type => 'anyexact'},
    user   => Bugzilla::User->super_user,
  )->data;
}

subtest 'valid flags still search with an unsafe flag stored' => sub {
  my $data;
  ok(lives { $data = run_search($safe[0]) }, 'one flag: two-stage search runs')
    or note $@;
  is($data,            [[$bug_id, '---']], 'one flag: row comes back');
  is(scalar @executed, 2,                  'one flag: both stages executed');

  ok(lives { $data = run_search(@safe) }, '31 flags: placeholder search runs')
    or note $@;
  is($data, [[$bug_id, ('---') x 31]], '31 flags: row comes back');
  like(
    $executed[-1],
    qr/'---' AS cf_tracking_safe_01/,
    '31 flags: placeholder path was taken'
  );
};

subtest 'unsafe stored flag is refused before its SQL runs' => sub {
  like(
    dies { run_search($legacy) },
    qr/as\s+a\s+field\s+name/,
    'two-stage search is refused'
  );
  is(scalar @executed, 1, 'only the bug_id stage ran');
  ok(!(grep {/$marker/} @executed), 'payload never reached the database');

  like(dies { run_search(@safe[0 .. 29], $legacy) },
    qr/as\s+a\s+field\s+name/, 'more-than-30-flag placeholder search is refused');
  ok(!(grep {/$marker/} @executed), 'payload never reached the database');
};

done_testing;
