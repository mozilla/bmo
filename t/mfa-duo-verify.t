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
use lib qw( . lib local/lib/perl5 );

use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockLocalconfig urlbase => 'http://bmo.test/';
use Bugzilla::Test::MockParams (duo_uri => 'http://duo.test/');
use Bugzilla::Test::Util qw(create_user);

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::MFA;
use Bugzilla::Token qw(issue_short_lived_session_token);
use JSON::MaybeXS qw(encode_json);
use Test::More;
use Try::Tiny;

BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);
Bugzilla->input_params({});

my $user = create_user('duo-user@mozilla.test', '*');
Bugzilla->set_user($user);
Bugzilla->dbh->do('UPDATE profiles SET mfa = ? WHERE userid = ?',
  undef, 'Duo', $user->id);

# Mint an mfa session token carrying $event, the way verify_prompt does.
# set_token_extra_data is not used directly because its upsert is MySQL-only.
sub mfa_token {
  my ($event) = @_;
  my $token = issue_short_lived_session_token('mfa', $user);
  Bugzilla->dbh->do('INSERT INTO token_data (token, extra_data) VALUES (?, ?)',
    undef, $token, encode_json($event));
  return $token;
}

sub dies_like {
  my ($code, $re, $name) = @_;
  my $err;
  try { $code->() } catch { $err = $_ };
  like($err // '(did not die)', $re, $name);
}

my $event = {
  reason   => 'creating an API key',
  actions  => [{type => 'create', description => 'test key'}],
  postback => {action => 'userprefs.cgi', fields => {tab => 'apikey'}},
};

my $provider = Bugzilla::MFA->new_from($user, 'Duo');
isa_ok($provider, 'Bugzilla::MFA::Duo');

# The core of bug 2060356: a session-cookie attacker can trigger verify_prompt
# and recover the mfa token from the Set-Cookie header without ever completing
# Duo. Replaying it must not yield a verified event.
dies_like(
  sub { $provider->verify_token(mfa_token($event), {no_delete => 1}) },
  qr/Invalid Duo Security MFA Code/,
  'verify_token rejects an event that never passed Duo'
);

# Duo's own callback runs before duo_verified exists, so it opts out.
{
  my $got = $provider->verify_token(mfa_token($event),
    {no_delete => 1, no_redirect => 1, provider_callback => 1});
  is($got->{reason}, 'creating an API key',
    'provider_callback bypasses the gate for the Duo callback itself');
}

# The happy path: the callback has recorded a successful code exchange.
{
  my $verified = {%$event, duo_verified => 1};
  my $got      = $provider->verify_token(mfa_token($verified));
  is($got->{actions}[0]{type}, 'create', 'verify_token accepts a verified event');
}

# A recovery code must not stand in for Duo verification. Duo users have no
# form to enter one, and generating them is now blocked outright.
dies_like(
  sub { $provider->generate_recovery_codes() },
  qr/Recovery codes are not available/,
  'Duo refuses to generate recovery codes'
);

# Providers that verify inline are unaffected: the base verify_event is a no-op.
{
  my $dummy = Bugzilla::MFA->new_from($user, 'Dummy');
  isa_ok($dummy, 'Bugzilla::MFA::Dummy');
  my $got = $dummy->verify_token(mfa_token($event), {no_delete => 1});
  is($got->{reason}, 'creating an API key',
    'non-Duo providers are not gated on duo_verified');
}

done_testing;
