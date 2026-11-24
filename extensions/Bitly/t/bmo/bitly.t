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
use Test::Mojo;
use Mojo::UserAgent;
use Mojolicious;

use Bugzilla;
BEGIN { Bugzilla->extensions }
use Bugzilla::Extension::Bitly::API::V1::Bitly;

# Stand-in for the Bitly API: echoes the long URL back as the short link.
my @sent;
my $bitly = Mojolicious->new;
$bitly->routes->post(
  '/v4/shorten' => sub {
    my $c = shift;
    push @sent, $c->req->json->{long_url};
    $c->render(json => {link => 'https://bit.ly/' . scalar @sent});
  }
);
{
  no warnings 'redefine';
  *Bugzilla::Extension::Bitly::API::V1::Bitly::mojo_user_agent = sub {
    my $ua = Mojo::UserAgent->new;
    $ua->server->app($bitly);
    $ua->on(
      start => sub {
        my $url = $_[1]->req->url;
        $url->scheme('http')->host('127.0.0.1')->port($ua->server->url->port);
      }
    );
    return $ua;
  };
}

my $urlbase = Bugzilla->localconfig->urlbase;
my $t       = Test::Mojo->new('Bugzilla::App');

$t->get_ok('/rest/bitly/shorten')
  ->status_is(400)
  ->json_like('/message' => qr/url/, 'url is required');

$t->get_ok('/rest/bitly/shorten' => form =>
    {url => 'https://example.com/buglist.cgi?bug_id=1'})
  ->status_is(400)
  ->json_like('/message' => qr/not supported/, 'other sites are refused');

$t->get_ok('/rest/bitly/shorten' => form =>
    {url => "${urlbase}buglist.cgi?bug_status=NEW&list_id=42"})
  ->status_is(200)
  ->json_is('/url' => 'https://bit.ly/1');
is($sent[-1], "${urlbase}buglist.cgi?bug_status=NEW", 'list_id is dropped');

$t->get_ok(
  '/rest/bitly/list' => form => {url => "${urlbase}buglist.cgi?bug_id=1,2"})
  ->status_is(200)
  ->json_is('/url' => 'https://bit.ly/2');
like(
  $sent[-1],
  qr{^\Q${urlbase}\Ebuglist\.cgi\?bug_id=[\d,]*$},
  'list shortens a bug_id only URL'
);

done_testing;
