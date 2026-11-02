# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
package main;
use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );
use Bugzilla::Constants;
use Bugzilla::Util qw(generate_random_password);
use Bugzilla::Token qw(issue_hash_token check_hash_token hash_token_time);
use Bugzilla::Localconfig;
use Digest::SHA qw(hmac_sha256_base64);
use Test2::V0;
use Test2::Tools::Mock qw(mock);

my $site_wide_secret = generate_random_password(256);
my $Localconfig = mock 'Bugzilla::Localconfig' => (
  add_constructor => [fake_new => 'ref_copy'],
  override => [
    site_wide_secret => sub { $site_wide_secret },
  ]
);

my $current_user_id;
{
  package Bugzilla;
  sub localconfig { Bugzilla::Localconfig->fake_new({}) }
  sub user        { bless {id => $current_user_id}, 'FakeUser' }
  sub usage_mode  { Bugzilla::Constants::USAGE_MODE_MOJO }
  sub template    { undef }

  package FakeUser;
  sub id { $_[0]->{id} }
}

# check_hash_token returns 1 on success and a hashref on failure
# when running in Mojo usage mode.
sub token_reason {
  my $result = check_hash_token(@_);
  return ref $result ? $result->{reason} : 'accepted';
}

my @data = (2, '2030-01-01 00:00:00');

# A normal token round-trips for the same user and data.
$current_user_id = 13;
my $token = issue_hash_token(\@data);
is(token_reason($token, \@data), 'accepted', 'valid token checks out');
is(token_reason($token, [1, $data[1]]),
  'invalid_token', 'token rejected for other data');

$current_user_id = 12;
is(token_reason($token, \@data), 'invalid_token',
  'token rejected for other user');

# Field-shifting forgery: the attacker (13) gets a MAC over data containing
# '*', then moves the leading fields into the time prefix so that it verifies
# for the victim (12) over different data.
$current_user_id = 13;
my $attacker_token = issue_hash_token([3, join('*', 'y', 12, @data)]);
my ($time, $hmac) = $attacker_token =~ /^(\d+)-(.+)$/;
my $forged = "$time*13*3*y-$hmac";

# Confirm the forgery is real: the stolen HMAC is exactly what the victim's
# HMAC input would produce, so only the time validation can stop it. This
# mirrors the HMAC input format in issue_hash_token; if that format changes,
# rework the forgery scenario rather than deleting this check.
my $victim_hmac
  = hmac_sha256_base64(join('*', $time, 13, 3, 'y', 12, @data),
  $site_wide_secret);
$victim_hmac =~ tr{+/}{-_};
is($hmac, $victim_hmac, 'attacker HMAC is valid for the victim input');

$current_user_id = 12;
is(token_reason($forged, \@data),
  'invalid_token', 'forged token with shifted fields is rejected');

# Other '*'-bearing time fields take the same invalid_token path.
foreach my $bad ("$time*-$hmac", "*$time-$hmac", "$time*12-$hmac",
  "$time*13*3*y--$hmac")
{
  is(token_reason($bad, \@data),
    'invalid_token', "token '$bad' reported as invalid");
}

is(token_reason('garbage', [2]), 'invalid_token', 'garbage token rejected');
is(token_reason('',        [2]), 'missing_token', 'missing token rejected');

# The issuer only accepts a purely numeric explicit time.
foreach my $bad_time ('123*13', 'abc', '-5', ' 123', '1e3', '12 34', "123\n",
  "\N{ARABIC-INDIC DIGIT ONE}\N{ARABIC-INDIC DIGIT TWO}")
{
  like(dies { issue_hash_token([2], $bad_time) },
    qr/Invalid hash token time/, "issuer refuses time '$bad_time'");
}

# hash_token_time is the single definition of the token format.
is(hash_token_time($token), ($token =~ /^(\d+)-/)[0],
  'hash_token_time returns the issue time');
foreach my $bad ($forged, "$time*-$hmac", "$time-$hmac\n", "$time-",
  "\N{ARABIC-INDIC DIGIT ONE}-$hmac", 'garbage', '', undef)
{
  my $label = defined $bad ? "'$bad'" : 'undef';
  is(scalar hash_token_time($bad), undef, "hash_token_time rejects $label");
}

my $explicit = time() - 60;
my $explicit_token = issue_hash_token([2], $explicit);
like($explicit_token, qr/^$explicit-/, 'issuer accepts numeric explicit time');
is(token_reason($explicit_token, [2]),
  'accepted', 'token with explicit time checks out');

done_testing();
