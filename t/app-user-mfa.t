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
use Bugzilla::Test::Util qw(create_user issue_api_key);

use Auth::GoogleAuth;
use Bugzilla::MFA;
use Bugzilla::Token qw(issue_short_lived_session_token);
use Test2::V0;
use Test::Mojo;

# GET /rest/user/mfa/totp/enroll (js/account.js) and
# POST /rest/user/mfa/verify_totp_code (js/mfa_totp.js).

# MFA properties are stored with MySQL's ON DUPLICATE KEY UPDATE, which the
# SQLite test database does not support, so keep them in a hash instead.
my %props;
my $props_mock = mock 'Bugzilla::MFA' => (
  override => [
    property_get    => sub { $props{$_[0]->{user}->id}{$_[1]} },
    property_set    => sub { $props{$_[0]->{user}->id}{$_[1]} = $_[2] },
    property_delete => sub { delete $props{$_[0]->{user}->id}{$_[1]} },
  ]
);

# Every account and token is created before the first request (see
# t/app-user-whoami.t).
my $enroller = create_user('enroll@mozilla.org', '*');
my $key      = issue_api_key('enroll@mozilla.org');
my $no_mfa   = create_user('nomfa@mozilla.org', '*');
my $totp     = create_user('totp@mozilla.org',  '*');

Bugzilla->set_user(Bugzilla::User->super_user);
$totp->set_mfa('TOTP');
$totp->update();
Bugzilla->set_user(Bugzilla::User->new);

my $secret = 'abcdefghijklmnop';
$props{$totp->id} = {secret => $secret, 'recovery.1' => '123456789'};

my $no_mfa_token = issue_short_lived_session_token('mfa', $no_mfa);
my $totp_token   = issue_short_lived_session_token('mfa', $totp);

my $t = Test::Mojo->new('Bugzilla::App');

# Enrollment needs a logged-in user.
$t->get_ok('/rest/user/mfa/totp/enroll')
  ->status_is(401)
  ->json_is('/code' => 410);

my %auth = ('X-Bugzilla-API-Key' => $key->api_key);
$t->get_ok('/rest/user/mfa/totp/enroll' => \%auth)
  ->status_is(200)
  ->json_has('/png');
my $temp_secret = $props{$enroller->id}{'secret.temp'};
ok($temp_secret, 'A temporary secret is stored');
is(
  Auth::GoogleAuth->new({secret32 => $t->tx->res->json('/secret32')})->code,
  Auth::GoogleAuth->new({secret   => $temp_secret})->code,
  'secret32 is the temporary secret'
);
is(Bugzilla::User->new($enroller->id)->mfa,
  '', 'MFA is not enabled until the user confirms it');

$props{$enroller->id}{secret} = $secret;
$t->get_ok('/rest/user/mfa/totp/enroll' => \%auth)
  ->status_isnt(200)
  ->json_like('/message' => qr/already enrolled/);

# Duo has no enrollment API (and without duo_uri is not even configured).
$t->get_ok('/rest/user/mfa/duo/enroll' => \%auth)
  ->status_is(200)
  ->content_is('null');

$t->get_ok('/rest/user/mfa/unknown/enroll' => \%auth)
  ->status_is(400)
  ->json_like('/message' => qr/Unknown MFA provider/);

$t->options_ok('/rest/user/mfa/totp/enroll')
  ->status_is(200)
  ->header_is(Allow => 'GET');

# Verification identifies the user by the token from the form.
my $verify = '/rest/user/mfa/verify_totp_code';

$t->post_ok($verify => json => {mfa_token => 'bogus', mfa_code => '000000'})
  ->status_is(200);
$t->json_is('/error' => 1)->json_is('/message' => 'invalid verification token');

$t->post_ok(
  $verify => json => {mfa_token => $no_mfa_token, mfa_code => '000000'})
  ->status_is(200);
$t->json_is('/error' => 1)->json_is('/message' => 'mfa not enabled');

my $code  = Auth::GoogleAuth->new({secret => $secret})->code;
my $wrong = sprintf('%06d', ($code + 1) % 1_000_000);
$t->post_ok($verify => json => {mfa_token => $totp_token, mfa_code => $wrong})
  ->status_isnt(200);
$t->json_is('/error'   => Mojo::JSON->true)
  ->json_is('/message' => 'Invalid verification code.');

$t->post_ok($verify => json => {mfa_token => $totp_token, mfa_code => $code})
  ->status_is(200)
  ->json_is('/error' => 0);

# A recovery code is accepted but not used up: the form submission does that.
$t->post_ok(
  $verify => json => {mfa_token => $totp_token, mfa_code => '123456789'})
  ->status_is(200)
  ->json_is('/error' => 0);
is($props{$totp->id}{'recovery.1'}, '123456789', 'Recovery code still unused');

$t->options_ok($verify)->status_is(200)->header_is(Allow => 'POST');

done_testing;
