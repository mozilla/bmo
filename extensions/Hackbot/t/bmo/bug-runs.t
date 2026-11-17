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

use Test::More;
use HTTP::Response;
use JSON qw(encode_json);

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::User;
use Bugzilla::Extension::Hackbot::BugRuns;
use Bugzilla::Extension::Hackbot::Client;

# A bug id no fixture uses, varied per process so re-runs don't share cache.
my $BUG_ID    = 1_900_000_000 + ($$ % 100_000);
my $CACHE_KEY
  = Bugzilla::Extension::Hackbot::BugRuns::CACHE_KEY_PREFIX . $BUG_ID;

Bugzilla->params->{hackbot_ui_url} = 'https://hackbot.example.test/';

my $requester = Bugzilla::User->new({name => 'automation@bmo.tld'});

sub run_doc {
  my (%over) = @_;
  my $inputs = delete $over{inputs} // {bug_id => $BUG_ID};
  return {
    run_id        => '53bbcc6e-014c-487b-b0e8-8a6b7b0ec273',
    agent         => 'bug-fix',
    status        => 'running',
    inputs        => $inputs,
    requested_by  => undef,
    requested_via => undef,
    created_at    => '2026-11-12T16:24:39.123456Z',
    %over,
  };
}

# Records each request and answers from a queue of HTTP::Response objects.
package FakeUA {
  sub new { bless {responses => [@_[1 .. $#_]], requests => []}, $_[0] }

  sub get {
    my ($self, $url, %headers) = @_;
    push @{$self->{requests}}, {url => $url, headers => \%headers};
    return shift @{$self->{responses}};
  }
}

# Stands in for the Client: returns queued results and records the ETag sent.
package FakeClient {
  sub new { bless {results => [@_[1 .. $#_]], etags => []}, $_[0] }

  sub bug_runs {
    my ($self, $bug_id, $etag) = @_;
    push @{$self->{etags}}, $etag;
    return shift @{$self->{results}};
  }
  sub calls { scalar @{$_[0]->{etags}} }
}

package main;

sub response {
  my ($code, $body, %headers) = @_;
  return HTTP::Response->new($code, undef,
    ['Content-Type' => 'application/json', %headers], $body);
}

sub client_with {
  my $ua     = FakeUA->new(@_);
  my $client = Bugzilla::Extension::Hackbot::Client->new(
    base_url => 'https://hackbot-api.example.test/',
    api_key  => 'secret-key',
    ua       => $ua,
  );
  return ($client, $ua);
}

sub reset_cache {
  Bugzilla->memcached->set_data({key => $CACHE_KEY, value => undef});
}

# Age the cached entry past its freshness window.
sub expire_cache {
  my $entry = Bugzilla->memcached->get_data({key => $CACHE_KEY});
  $entry->{fresh_until} = time() - 1;
  Bugzilla->memcached->set_data({key => $CACHE_KEY, value => $entry});
}

sub fetch {
  my ($client) = @_;
  return Bugzilla::Extension::Hackbot::BugRuns->for_bug($BUG_ID,
    client => $client);
}

subtest 'client: request shape and conditional requests' => sub {
  my ($client, $ua) = client_with(
    response(200, encode_json({runs => [run_doc()]}), ETag => '"v1"'),
    response(304, '',                                 ETag => '"v1"'),
  );

  my $result = $client->bug_runs($BUG_ID);
  ok($result->{ok}, '200 is ok');
  is($result->{etag},           '"v1"', 'ETag is returned');
  is(scalar @{$result->{runs}}, 1,      'runs are returned');

  my $request = $ua->{requests}[0];
  is(
    $request->{url},
    "https://hackbot-api.example.test/bugs/$BUG_ID/runs",
    'lists the runs for the bug'
  );
  is($request->{headers}{'X-API-Key'}, 'secret-key', 'sends the API key');
  ok(!exists $request->{headers}{'If-None-Match'},
    'first request is unconditional');

  $result = $client->bug_runs($BUG_ID, '"v1"');
  ok($result->{ok} && $result->{not_modified}, '304 means not modified');
  is($ua->{requests}[1]{headers}{'If-None-Match'}, '"v1"', 'sends If-None-Match');
};

subtest 'client: response without an ETag' => sub {
  my ($client) = client_with(response(200, encode_json({runs => [run_doc()]})));
  my $result = $client->bug_runs($BUG_ID);
  ok($result->{ok}, 'ok without an ETag');
  is(scalar @{$result->{runs} // []}, 1,     'runs are returned');
  is($result->{etag},                 undef, 'no ETag to revalidate with');
};

subtest 'client: UTF-8 response with a charset' => sub {
  my $comment = "Caf\x{e9} \x{2014} \x{2713}";
  my $body = encode_json(
    {runs => [run_doc(inputs => {bug_id => $BUG_ID, comment => $comment})]});
  my ($client) = client_with(HTTP::Response->new(
    200, undef, ['Content-Type' => 'application/json; charset=utf-8'], $body
  ));

  my $result = $client->bug_runs($BUG_ID);
  ok($result->{ok}, 'non-ASCII JSON is parsed');
  is($result->{runs}[0]{inputs}{comment}, $comment, 'text is decoded once');
};

subtest 'client: failures' => sub {
  my ($client) = client_with(
    response(500, 'oops'),
    response(200, '{"not":"runs"}'),
    response(200, encode_json([run_doc()])),
    response(200, 'not json'),
  );
  ok(!$client->bug_runs($BUG_ID)->{ok}, 'HTTP error is not ok');
  ok(!$client->bug_runs($BUG_ID)->{ok}, 'body without runs is not ok');
  ok(!$client->bug_runs($BUG_ID)->{ok}, 'bare list body is not ok');
  ok(!$client->bug_runs($BUG_ID)->{ok}, 'invalid JSON is not ok');

  my $unconfigured = Bugzilla::Extension::Hackbot::Client->new(
    base_url => '',
    ua       => FakeUA->new()
  );
  ok(!$unconfigured->bug_runs($BUG_ID)->{ok}, 'missing API URL is not ok');
};

subtest 'runs are trimmed to valid runs for this bug' => sub {
  reset_cache();
  my $client = FakeClient->new({
    ok   => 1,
    etag => '"t"',
    runs => [
      run_doc(),
      run_doc(run_id => 'not-a-uuid'),
      run_doc(inputs => {bug_id => $BUG_ID + 1}),
      run_doc(inputs => {}),
      'not a hash',
    ],
  });

  my $result = fetch($client);
  ok($result->{ok}, 'ok');
  is(scalar @{$result->{runs}}, 1, 'only the valid run for this bug is kept');

  my $run = $result->{runs}[0];
  is(
    $run->{url},
    'https://hackbot.example.test/runs/53bbcc6e-014c-487b-b0e8-8a6b7b0ec273',
    'run link points at the Hackbot UI'
  );
  is($run->{agent},      'bug-fix',                     'agent');
  is($run->{status},     'running',                     'status');
  is($run->{created_at}, '2026-11-12T16:24:39.123456Z', 'created_at');
};

subtest 'runs are capped at the newest HACKBOT_MAX_RUNS' => sub {
  reset_cache();
  my $max  = Bugzilla::Extension::Hackbot::Constants::HACKBOT_MAX_RUNS;
  my @docs = map {
    run_doc(run_id => sprintf('00000000-0000-0000-0000-%012d', $_))
  } 1 .. $max + 5;

  # Another bug's run is dropped and does not count towards the cap.
  unshift @docs, run_doc(inputs => {bug_id => $BUG_ID + 1});
  my $client = FakeClient->new({ok => 1, runs => \@docs});

  my $runs = fetch($client)->{runs};
  is(scalar @$runs, $max, 'list is capped');
  like($runs->[0]{url},  qr/-000000000001$/,  'newest run is kept');
  like($runs->[-1]{url}, qr/-0*\Q$max\E$/, 'cut after the cap');
};

subtest 'origin and requester' => sub {
  reset_cache();
  my $client = FakeClient->new({
    ok   => 1,
    runs => [
      run_doc(
        run_id       => '00000000-0000-0000-0000-000000000001',
        inputs       => {bug_id => $BUG_ID, bugzilla_needinfo_flag_id => 42},
        requested_by => $requester->login,
      ),
      run_doc(
        run_id        => '00000000-0000-0000-0000-000000000002',
        requested_via => 'hackbot-ui-run@some-project.iam.gserviceaccount.com',
        requested_by  => 'not-a-bmo-user@example.test',
        status        => 'something-new',
      ),
      run_doc(
        run_id     => '00000000-0000-0000-0000-000000000003',
        dedupe_key => 'phab-txn:PHID-XACT-DREV-abc123',
        inputs     => {bug_id => $BUG_ID, revision_id => 218404},
      ),
      run_doc(
        run_id        => '00000000-0000-0000-0000-000000000004',
        requested_via => 'hackbot-pulse-listener-run@p.iam.gserviceaccount.com',
      ),
      run_doc(
        run_id     => '00000000-0000-0000-0000-000000000005',
        dedupe_key => 'parent-0f6a2c1e-7d1b-4c3e-9a55-2b8e6f1d4c90',

        # Whichever component started it, a follow-up is labelled as one.
        requested_via => 'hackbot-api@p.iam.gserviceaccount.com',
      ),
      run_doc(
        run_id     => '00000000-0000-0000-0000-000000000006',
        dedupe_key => 'phab-txn:PHID-XACT-DREV-def456',         # no revision_id
      ),
      run_doc(run_id => '00000000-0000-0000-0000-000000000007'),
    ],
  });

  my ($needinfo, $ui, $phab, $ci, $followup, $phab_no_rev, $other)
    = @{fetch($client)->{runs}};
  is($needinfo->{origin},    'needinfo',       'needinfo run');
  is($needinfo->{requester}, $requester->nick, 'requester shown by nick');
  is($ui->{origin},          'ui',             'Hackbot UI run');
  is($ui->{requester},       undef,            'unknown email has no requester');
  is($ui->{status},          'unknown',        'unrecognized status');
  is($phab->{origin},        'phabricator',    'Phabricator @hackbot run');
  is($phab->{revision},      218404,           'with its revision');
  is($ci->{origin},          'ci',             'CI (pulse listener) run');
  is($followup->{origin},    'followup',       'follow-up run');
  is($phab_no_rev->{origin}, 'other', 'Phabricator key without a revision');
  is($other->{origin},       'other', 'anything else');
  is($other->{revision},     undef,   'revision only for Phabricator');
  ok(
    !grep({ exists $_->{requested_by} || exists $_->{dedupe_key} } $needinfo,
      $ui, $phab, $ci, $followup, $other),
    'requester emails and dedupe keys are not exposed'
  );
};

SKIP: {
  skip 'memcached is not enabled', 1 unless Bugzilla->memcached->enabled;

  subtest 'ETag caching' => sub {
    reset_cache();
    my $client = FakeClient->new(
      {ok => 1, etag         => '"v1"', runs   => [run_doc()]},
      {ok => 1, not_modified => 1,      etag   => '"v1"'},
      {ok => 0, status       => 503,    errmsg => 'down'},
    );

    is(scalar @{fetch($client)->{runs}}, 1, 'first load fetches');
    fetch($client);
    is($client->calls, 1, 'fresh cache is served without a request');

    expire_cache();

    my $result = fetch($client);
    is($client->{etags}[1],       '"v1"', 'stale cache revalidates with its ETag');
    is(scalar @{$result->{runs}}, 1,      '304 reuses the cached runs');

    expire_cache();

    ok(!fetch($client)->{ok}, 'API failure is reported');
    ok(!fetch($client)->{ok}, 'failure is cached');
    is($client->calls, 3, 'cached failure makes no further request');
  };
}

reset_cache();
done_testing();
