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
use Bugzilla::Test::Util qw(create_bug create_user);
use Bugzilla::Search;
use Bugzilla::User;
use Test2::V0;

# Search changed* on flags matches changes in flag_activity and the older
# ones that are only in bugs_activity.

create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

my $alice = create_user('alice@bmo.test', '*');
my $bob   = create_user('bob@bmo.test',   '*');

sub new_bug {
  return create_bug(
    short_desc  => shift,
    comment     => 'Flag search test bug',
    bug_type    => 'defect',
    assigned_to => 'nobody@mozilla.org',
  )->id;
}

my ($fieldid)
  = $dbh->selectrow_array(
  "SELECT id FROM fielddefs WHERE name = 'flagtypes.name'");
my ($review_id)
  = $dbh->selectrow_array("SELECT id FROM flagtypes WHERE name = 'review'");

# Legacy: review+ by bob in 2020, only in bugs_activity.
my $legacy_bug = new_bug('legacy');
$dbh->do(
  'INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
   VALUES (?, ?, ?, ?, ?, ?)', undef, $legacy_bug, $bob->id,
  '2020-01-01 10:00:00', $fieldid, '', 'review+'
);

# Current: alice asks bob for review, then grants it, only in flag_activity.
my $current_bug = new_bug('current');
for my $row (['2026-01-01 10:00:00', '?', $bob->id],
  ['2026-01-02 10:00:00', '+', undef])
{
  $dbh->do(
    'INSERT INTO flag_activity
       (flag_when, type_id, flag_id, setter_id, who, requestee_id, bug_id,
        status)
     VALUES (?, ?, 42, ?, ?, ?, ?, ?)', undef, $row->[0], $review_id,
    $alice->id, $alice->id, $row->[2], $current_bug, $row->[1]
  );
}

sub search {
  my ($operator, $value) = @_;
  my $search = Bugzilla::Search->new(
    fields => ['bug_id'],
    params => {f1 => 'flagtypes.name', o1 => $operator, v1 => $value},
  );
  return [sort { $a <=> $b } map { $_->[0] } @{$search->data}];
}

is(search(changedto => 'review+'), [$legacy_bug, $current_bug], 'changedto');
is(search(changedto => 'review?(bob@bmo.test)'), [$current_bug],
  'changedto with requestee');
is(search(changedfrom => 'review?(bob@bmo.test)'), [$current_bug],
  'changedfrom uses the previous flag_activity row');
is(search(changedfrom => 'review+'), [], 'changedfrom no match');
is(search(changedbefore => '2021-01-01'), [$legacy_bug],  'changedbefore');
is(search(changedafter  => '2025-01-01'), [$current_bug], 'changedafter');
is(search(changedby => 'alice@bmo.test'), [$current_bug],
  'changedby flag_activity');
is(search(changedby => 'bob@bmo.test'), [$legacy_bug],
  'changedby bugs_activity');
is(search(everchanged => ''), [$legacy_bug, $current_bug], 'everchanged');

# Changes to any field include flag changes.
sub search_anything {
  my ($operator, $value) = @_;
  my $search = Bugzilla::Search->new(
    fields => ['bug_id'],
    params => {f1 => 'anything', o1 => $operator, v1 => $value},
  );
  return [sort { $a <=> $b } map { $_->[0] } @{$search->data}];
}
is(search_anything(changedby => 'alice@bmo.test'), [$current_bug],
  'anything changedby flag_activity');
is(search_anything(changedby => 'bob@bmo.test'), [$legacy_bug],
  'anything changedby bugs_activity');
is(search_anything(changedafter => '2025-01-01'), [$current_bug],
  'anything changedafter');
is(search_anything(changedto => 'review+'), [$legacy_bug, $current_bug],
  'anything changedto');
is(search_anything(changedfrom => 'review?(bob@bmo.test)'), [$current_bug],
  'anything changedfrom');

# An assignee whose only recent changes are flag changes isn't idle.
my $owned_bug = create_bug(
  short_desc  => 'owned',
  comment     => 'Flag search test bug',
  bug_type    => 'defect',
  assigned_to => 'alice@bmo.test',
)->id;
sub idle {
  my ($operator) = @_;
  my $search = Bugzilla::Search->new(
    fields => ['bug_id'],
    params => {
      f1 => 'owner_idle_time', o1 => $operator,  v1 => '2025-12-01',
      f2 => 'assigned_to',     o2 => 'equals',   v2 => 'alice@bmo.test',
    },
  );
  return [map { $_->[0] } @{$search->data}];
}
is(idle('lessthan'),    [$owned_bug], 'owner_idle_time lessthan');
is(idle('greaterthan'), [],           'owner_idle_time greaterthan');

done_testing;
