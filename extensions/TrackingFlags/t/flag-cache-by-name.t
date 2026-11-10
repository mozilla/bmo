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

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Constants;
use Bugzilla::Extension::TrackingFlags::Flag;
use Test2::V0;

# Tracking flag lookups by name should be served from the request cache when
# the flag is already loaded, and fall back to the database otherwise.

my $FLAG = 'Bugzilla::Extension::TrackingFlags::Flag';
my @db_lookups;
my $mock_object = mock 'Bugzilla::Object' => (
  override => [
    new => sub {
      my ($class, $param) = @_;
      push @db_lookups, $param;
      return undef;
    }
  ]
);

sub flag { bless {id => $_[0], name => $_[1]}, $FLAG }

sub new_request {
  my (%flags) = @_;
  Bugzilla->clear_request_cache;
  Bugzilla->request_cache->{tracking_flags}
    = {map { $_->flag_id => $_ } values %flags}
    if %flags;
  @db_lookups = ();
}

subtest 'cached flag found by name without a query' => sub {
  my $a = flag(1, 'cf_status_firefox140');
  new_request(a => $a);
  is($FLAG->new({name => 'cf_status_firefox140'}), exact_ref($a),
    'cached object');
  is($FLAG->new({name => 'CF_STATUS_FIREFOX140'}),
    exact_ref($a), 'case-insensitive, like the database lookup');
  is(scalar @db_lookups, 0, 'no database lookups');
};

subtest 'unknown name falls back to the database' => sub {
  new_request(a => flag(1, 'cf_status_firefox140'));
  is($FLAG->new({name => 'cf_rank'}), undef, 'not a tracking flag');
  is(\@db_lookups, [{name => 'cf_rank'}],    'one database lookup');
};

subtest 'no request cache: database lookup' => sub {
  new_request();
  $FLAG->new({name => 'cf_status_firefox140'});
  is(scalar @db_lookups, 1, 'database lookup');
};

subtest 'index follows changes to the cache' => sub {
  my $a = flag(1, 'cf_status_firefox140');
  new_request(a => $a);
  $FLAG->new({name => 'cf_status_firefox140'});    # builds the index

  # A flag added to the cache later (e.g. by update()) is found.
  my $b = flag(2, 'cf_status_firefox141');
  Bugzilla->request_cache->{tracking_flags}{2} = $b;
  is($FLAG->new({name => 'cf_status_firefox141'}), exact_ref($b), 'new flag');

  # A renamed flag is not returned under its old name.
  $a->{name} = 'cf_status_firefox_renamed';
  is($FLAG->new({name => 'cf_status_firefox140'}), undef, 'old name');
  is(scalar @db_lookups, 1, 'old name went to the database');

  # A flag removed from the cache (remove_from_db()) is not returned.
  delete Bugzilla->request_cache->{tracking_flags}{2};
  @db_lookups = ();
  is($FLAG->new({name => 'cf_status_firefox141'}), undef, 'removed flag');
  is(scalar @db_lookups, 1, 'removed flag went to the database');
};

subtest 'id lookups are unchanged' => sub {
  my $a = flag(1, 'cf_status_firefox140');
  new_request(a => $a);
  is($FLAG->new(1),      exact_ref($a), 'cached by id');
  is(scalar @db_lookups, 0,             'no database lookups');
};

subtest 'bug_check_can_change_field skips non-tracking fields' => sub {
  my $a = flag(1, 'cf_status_firefox140');
  new_request(a => $a);
  my $mock_names = mock 'Bugzilla' =>
    (override => [tracking_flag_names => sub {'cf_status_firefox140'}]);
  my $mock_flag = mock $FLAG => (override => [can_set_value => sub {1}]);

  my @results;
  my $check = sub {
    my ($field) = @_;
    Bugzilla::Extension::TrackingFlags->bug_check_can_change_field({
      bug          => undef,
      field        => $field,
      old_value    => '---',
      new_value    => 'fixed',
      priv_results => \@results,
    });
  };

  $check->('cf_rank');
  is(\@results,    [], 'non-tracking field: no result');
  is(\@db_lookups, [], 'non-tracking field: no database lookup');

  $check->('cf_status_firefox140');
  is(\@results, [{result => PRIVILEGES_REQUIRED_NONE}], 'tracking flag checked');
  is(\@db_lookups, [], 'tracking flag served from the request cache');
};

done_testing;
