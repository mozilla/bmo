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
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;
use Bugzilla::Test::Util qw(create_user mock_useragent_tx);
use Test::More;
use Test2::Tools::Mock;
use Try::Tiny;
use JSON::MaybeXS;
use Bugzilla::Constants;
use URI;
use File::Basename;
use Digest::SHA qw(sha1_hex);

use ok 'Bugzilla::Extension::PhabBugz::Feed';
use ok 'Bugzilla::Extension::PhabBugz::Constants', 'PHAB_AUTOMATION_USER';
use ok 'Bugzilla::Config',                         'SetParam';
can_ok(
  'Bugzilla::Extension::PhabBugz::Feed',
  qw( group_query feed_query user_query reviewer_is_blocking )
);

# `reviewer_is_blocking` must only treat `#release-managers` as
# already-requested when it is present as a blocking reviewer. A reviewer
# added manually through the Phabricator UI defaults to non-blocking.
{
  my $relman_phid = 'PHID-PROJ-releasemanagers';

  ok(
    Bugzilla::Extension::PhabBugz::Feed::reviewer_is_blocking(
      [{reviewerPHID => $relman_phid, isBlocking => 1}], $relman_phid
    ),
    '`reviewer_is_blocking` is true for a blocking reviewer.'
  );

  ok(
    !Bugzilla::Extension::PhabBugz::Feed::reviewer_is_blocking(
      [{reviewerPHID => $relman_phid, isBlocking => 0}], $relman_phid
    ),
    '`reviewer_is_blocking` is false for a non-blocking reviewer.'
  );

  ok(
    !Bugzilla::Extension::PhabBugz::Feed::reviewer_is_blocking(
      [{reviewerPHID => 'PHID-USER-someone', isBlocking => 1}], $relman_phid
    ),
    '`reviewer_is_blocking` is false when the reviewer is absent.'
  );
}

Bugzilla->error_mode(ERROR_MODE_TEST);

my $phab_bot = create_user(PHAB_AUTOMATION_USER, '*');

my $UserAgent = mock 'Mojo::UserAgent' => ();

{
  SetParam('phabricator_enabled', 0);
  my $feed = Bugzilla::Extension::PhabBugz::Feed->new;
  my $Feed = mock 'Bugzilla::Extension::PhabBugz::Feed' =>
    (override => [get_last_id => sub { die "get_last_id" },],);

  foreach my $method (qw( feed_query user_query group_query )) {
    try {
      $feed->$method;
      pass "disabling the phabricator sync: $method";
    }
    catch {
      fail "disabling the phabricator sync: $method";
    }
  }
}

my @bad_response = (
  ['HTTP error',   mock_useragent_tx("doesn't matter", sub { $_->code(500) })],
  ['invalid JSON', mock_useragent_tx('<xml>foo</xml>')],
  [
    'JSON containing error code (non-object error)',
    mock_useragent_tx(
      encode_json({error_code => 1234, error_info => 'Some random error'})
    )
  ],
  [
    'JSON containing error code (error)',
    mock_useragent_tx(encode_json({
      error_code => 1234,
      error_info => 'does not identify a valid object in query'
    }))
  ],
);

SetParam(phabricator_enabled  => 1);
SetParam(phabricator_api_key  => 'FAKE-API-KEY');
SetParam(phabricator_base_uri => 'http://fake.fabricator.tld/');

foreach my $bad_response (@bad_response) {
  my $feed = Bugzilla::Extension::PhabBugz::Feed->new;
  $UserAgent->override(
    post => sub {
      my ($self, $url, undef, $params) = @_;
      return $bad_response->[1];
    }
  );

  foreach my $method (qw( feed_query user_query group_query )) {
    try {
      # This is a hack to get reasonable exception objects.
      local $Bugzilla::Template::is_processing = 1;
      $feed->$method;
      fail "$method - $bad_response->[0]";
    }
    catch {
      is(
        $_->type,
        'bugzilla.code.phabricator_api_error',
        "$method - $bad_response->[0]"
      );
    };
  }
  $UserAgent->reset('post');
}

# `feed_lag_seconds` reports the age of the oldest unprocessed story.
{
  my $now = 1_000_000;

  is(Bugzilla::Extension::PhabBugz::Feed::feed_lag_seconds([], $now),
    0, '`feed_lag_seconds` is 0 when there are no new stories.');

  is(
    Bugzilla::Extension::PhabBugz::Feed::feed_lag_seconds(
      [{id => 1, epoch => $now - 600}, {id => 2, epoch => $now - 60}], $now
    ),
    600,
    '`feed_lag_seconds` uses the epoch of the oldest story.'
  );

  is(
    Bugzilla::Extension::PhabBugz::Feed::feed_lag_seconds(
      [{id => 1, epoch => $now + 30}], $now
    ),
    0,
    '`feed_lag_seconds` does not go negative when clocks are skewed.'
  );
}

# `feed_query` sends lag gauges before processing, even if a story fails.
{
  my %gauges;
  my $datadog = mock {} => (
    add => [
      gauge     => sub { my ($self, $name, $value) = @_; $gauges{$name} = $value },
      increment => sub { },
    ]
  );
  my $Bugzilla = mock 'Bugzilla' => (override => [datadog => sub {$datadog}]);

  my $oldest_epoch = time - 900;
  my $Feed         = mock 'Bugzilla::Extension::PhabBugz::Feed' => (
    override => [
      get_last_id => sub {5},
      new_stories => sub { [
        {id => 6, epoch => $oldest_epoch,     text => 'story 6'},
        {id => 7, epoch => $oldest_epoch + 1, text => 'story 7'},
      ] },
      _process_feed_story => sub { die "poison story\n" },
    ]
  );

  my $error;
  try { Bugzilla::Extension::PhabBugz::Feed->new->feed_query }
  catch { $error = $_ };

  is($error, "poison story\n", '`feed_query` propagates the story failure.');
  cmp_ok($gauges{'bugzilla.phabbugz.feed_lag_seconds'},
    '>=', 900, '`feed_lag_seconds` gauge is sent before the failing story.');
  is($gauges{'bugzilla.phabbugz.feed_pending_stories'},
    2, '`feed_pending_stories` gauge counts the fetched stories.');
}

my $feed = Bugzilla::Extension::PhabBugz::Feed->new;
my $json = JSON::MaybeXS->new(canonical => 1, pretty => 1);
my $dylan
  = create_user('dylan@mozilla.com', '*', realname => 'Dylan Hardison :dylan');
my $evildylan
  = create_user('dylan@gmail.com', '*', realname => 'Evil Dylan :dylan');
my $myk = create_user('myk@mozilla.com', '*', realname => 'Myk Melez :myk');

my $phab_bot_phid = next_phid('PHID-USER');

done_testing;

sub user_search {
  my (%conf) = @_;

  return {
    error_info => undef,
    error_code => undef,
    result     => {
      cursor =>
        {after => $conf{after}, order => undef, limit => 100, before => undef},
      query => {queryKey => undef},
      maps  => {},
      data  => [
        map {
          +{
            attachments => {
              $_->{bmo_id}
              ? ("external-accounts" =>
                  {"external-accounts" => [{type => 'bmo', id => $_->{bmo_id},}]})
              : (),
            },
            fields => {
              roles        => ["verified", "approved", "activated"],
              realName     => $_->{realname},
              dateModified => time,
              policy       => {view => "public", edit => "no-one"},
              dateCreated  => time,
              username     => $_->{username},
            },
            phid => next_phid("PHID-USER"),
            type => "USER",
            id   => $_->{phab_id},
            },
        } @{$conf{users}},
      ]
    }
  };

}

sub next_phid {
  my ($prefix) = @_;
  state $number = 'a' x 20;
  return $prefix . '-' . ($number++);
}


