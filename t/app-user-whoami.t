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
use Bugzilla::Test::MockParams (phabricator_base_uri => 'http://phab.test/');
use Bugzilla::Test::Util qw(create_user issue_api_key mock_useragent_tx);

use Bugzilla::Constants;
use Test2::V0;
use Mojo::JSON qw(encode_json);
use Test::Mojo;

# GET /rest/whoami is how a client validates an API key, so a key that is
# refused must say why (api_key_not_valid / api_key_revoked, internal code
# 306), as the legacy endpoint did, rather than the generic login_required
# (410) an anonymous request gets.

# Every account is created before the first request. The BMO extension logs
# the remote IP of whoever creates a user, which outside of a request only
# works until a request has left its controller behind.
my $user      = create_user('whoami@mozilla.org', '*');
my $phab_user = create_user('phab@mozilla.org',   '*');
my $key       = issue_api_key('whoami@mozilla.org');

my $t = Test::Mojo->new('Bugzilla::App');

$t->get_ok('/rest/whoami' => {'X-Bugzilla-API-Key' => $key->api_key})
  ->status_is(200)
  ->json_is('/id' => $user->id);

# No credentials at all.
$t->get_ok('/rest/whoami')->status_is(401)->json_is('/code' => 410);

# An unknown key, in the header or in the deprecated query parameters.
$t->get_ok('/rest/whoami' => {'X-Bugzilla-API-Key' => 'bogus-key-value'})
  ->status_isnt(200);
$t->json_is('/code' => 306)
  ->json_like('/message' => qr/API key you specified is invalid/);

foreach my $param (qw(api_key Bugzilla_api_key)) {
  $t->get_ok("/rest/whoami?$param=bogus-key-value")->status_isnt(200);
  $t->json_is('/code' => 306)
    ->json_like('/message' => qr/API key you specified is invalid/);
}

# A revoked key.
Bugzilla->set_user(Bugzilla::User->super_user);
$key->set_revoked(1);
$key->update();
Bugzilla->set_user(Bugzilla::User->new);

$t->get_ok('/rest/whoami' => {'X-Bugzilla-API-Key' => $key->api_key})
  ->status_isnt(200);
$t->json_is('/code' => 306)->json_like('/message' => qr/has been revoked/);

# Phabricator calls whoami with X-Phabricator-Token instead of an API key, to
# learn who the token belongs to and whether they have MFA enabled. Bugzilla
# asks Phabricator's user.whoami for the token's email; that request is
# stubbed here.
my $phab_response;
{

  package FakePhabUA;
  sub new        { return bless {}, shift }
  sub transactor { return $_[0] }
  sub name       {return}
  sub get { return Bugzilla::Test::Util::mock_useragent_tx($phab_response) }
}
my $ua_mock = mock 'Bugzilla::API::V1::UserObject' =>
  (override => [mojo_user_agent => sub { FakePhabUA->new }]);

my %phab = ('X-Phabricator-Token' => 'api-stub');

$phab_response = encode_json({result => {primaryEmail => 'phab@mozilla.org'}});
$t->get_ok('/rest/whoami' => \%phab)->status_is(200);
$t->json_is('/id'         => $phab_user->id)
  ->json_is('/mfa_status' => Mojo::JSON->false);

# A token Phabricator rejects, or one for an email Bugzilla does not know.
$phab_response = encode_json({error_info => 'API token is not valid.'});
$t->get_ok('/rest/whoami' => \%phab)->status_isnt(200)->json_is('/code' => 306);

$phab_response = encode_json({result => {primaryEmail => 'unknown@phab.test'}});
$t->get_ok('/rest/whoami' => \%phab)->status_isnt(200)->json_is('/code' => 306);

# A disabled account is refused (account_disabled, internal code 301), as it
# is with an API key.
Bugzilla->set_user(Bugzilla::User->super_user);
$phab_user->set_disabledtext('Contract ended. Access revoked.');
$phab_user->update();
Bugzilla->set_user(Bugzilla::User->new);

$phab_response = encode_json({result => {primaryEmail => 'phab@mozilla.org'}});
$t->get_ok('/rest/whoami' => \%phab)->status_is(401)->json_is('/code' => 301);

done_testing;
