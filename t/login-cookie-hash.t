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
use Bugzilla::Test::MockParams;
use Bugzilla::Test::Util qw(create_user);

use Test2::V0;

use Bugzilla;
use Bugzilla::Install::DB;
use Bugzilla::Token qw(issue_login_cookie hash_login_cookie);
use Bugzilla::Util qw(generate_random_password);

# The stored form of a login cookie is a keyed hash, never the cookie itself.
my ($cookie, $hash) = issue_login_cookie();
is(length $cookie, 22, 'a new login cookie has the usual token length');
my $HEX64 = qr/\A[[:xdigit:]]{64}\z/;
like($hash, $HEX64, 'its stored form is 64 hex chars');
is($hash, lc $hash, 'its stored form is lowercase');
is($hash, hash_login_cookie($cookie), 'the stored form is deterministic');
isnt($hash, $cookie, 'the raw cookie is not what gets stored');
isnt(hash_login_cookie($cookie . 'x'),
  $hash, 'a different cookie hashes differently');

# Cookies come from the browser, so odd input must not die.
like(hash_login_cookie('caf' . chr(0xE9) . chr(0x263A)),
  $HEX64, 'a cookie with wide characters still hashes');
like(hash_login_cookie(undef), $HEX64, 'a missing cookie hashes');

# Upgrading an install must rewrite existing raw cookies in place, so that
# users stay logged in, and must be a no-op when run again.
## no critic (Subroutines::ProtectPrivateSubs)
my $dbh  = Bugzilla->dbh;
my $user = create_user('cookie-hash@mozilla.test', '*');
my $raw  = generate_random_password(22);
$dbh->do(
  'INSERT INTO logincookies (cookie, userid, lastused) VALUES (?, ?, NOW())',
  undef, $raw, $user->id);

Bugzilla::Install::DB::_hash_login_cookies();
my $stored = $dbh->selectcol_arrayref(
  'SELECT cookie FROM logincookies WHERE userid = ?',
  undef, $user->id);
is($stored, [hash_login_cookie($raw)], 'upgrade replaces the raw cookie');

Bugzilla::Install::DB::_hash_login_cookies();
$stored = $dbh->selectcol_arrayref(
  'SELECT cookie FROM logincookies WHERE userid = ?',
  undef, $user->id);
is($stored, [hash_login_cookie($raw)], 'running the upgrade again is a no-op');

done_testing;
