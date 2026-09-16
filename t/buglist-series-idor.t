#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# buglist.cgi?cmdtype=dorem&remaction=runseries reads a chart series' saved
# query out of the series table and reflects it back into the rendered page as
# urlquerypart. That query is private data: it names products, components,
# groups and the email addresses of the people the series tracks.
#
# The read used to be a bare primary-key lookup with no authorization at all,
# so anyone -- including a logged out visitor -- could walk series_id and read
# every saved query in the installation. The two gates the rest of the charting
# code uses (chartgroup membership, and Bugzilla::Series' creator/is_public/
# category-group check) both now apply here, which is what this pins.

use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE} = 'log4perl-t.conf';

  # The Hostage plugin requires specific Host: headers; disable for tests.
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

# Before anything pulls in Bugzilla::Error: CGI::Compile installs
# CORE::GLOBAL::exit, and the legacy CGI wrapper relies on that to turn a
# script's exit into a catchable exception. Perl binds `exit` at compile time,
# so a Bugzilla module compiled ahead of CGI::Compile gets the real one and
# takes this test process down with it on the first ThrowUserError.
use CGI::Compile;

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;
use Bugzilla::Test::Util qw(create_user);

use Bugzilla;
use Bugzilla::App ();
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::Util qw(generate_random_password);

use Mojo::Cookie::Response;
use Test2::V0;
use Test::Mojo;

# A marker that only appears in the series' saved query, so "did the query
# leak" is a single substring check against the response body.
my $secret    = 'sekritwhiteboardmarker';
my $secret_re = qr/\Q$secret\E/;
my $query     = "bug_status=UNCONFIRMED&status_whiteboard=$secret";

my $dbh = Bugzilla->dbh;

my $owner    = create_user('series-owner@bmo.test',    '*');
my $charter  = create_user('series-charter@bmo.test',  '*');
my $outsider = create_user('series-outsider@bmo.test', '*');

# chartgroup defaults to editbugs, whose userregexp is '.*' (Bugzilla/Install.pm
# SYSTEM_GROUPS), so every user created above is already a member. Revoke that
# from the outsider only, leaving the owner and the charter with charting
# rights. The charter covers the second gate: a user who may use charts but has
# no business reading someone else's private series.
my $chartgroup = Bugzilla::Group->new({name => Bugzilla->params->{chartgroup}});
$dbh->do('DELETE FROM user_group_map WHERE user_id = ? AND group_id = ?',
  undef, $outsider->id, $chartgroup->id);

$dbh->do('INSERT INTO series_categories (name) VALUES (?)', undef, 'idor-cat');
my $category
  = $dbh->selectrow_array('SELECT id FROM series_categories WHERE name = ?',
  undef, 'idor-cat');

$dbh->do(
  'INSERT INTO series
          (creator, category, subcategory, name, frequency, query, is_public)
        VALUES (?, ?, ?, ?, 1, ?, 0)', undef, $owner->id, $category, $category,
  'idor-series', $query
);
my $series_id
  = $dbh->selectrow_array('SELECT series_id FROM series WHERE name = ?',
  undef, 'idor-series');

my $url = "/buglist.cgi?cmdtype=dorem&remaction=runseries&series_id=$series_id";

# One Test::Mojo for the whole file: building the app twice makes CGI::Compile
# die with "Tried to load admin.cgi more than once".
my $t  = Test::Mojo->new('Bugzilla::App');
my $ua = $t->ua;

# buglist.cgi redirects a logged in user to a canonical search URL before it
# looks at cmdtype at all, so without this the interesting cases would only
# ever assert against an empty 302 body.
$ua->max_redirects(3);

# Log in the way Bugzilla::App::Plugin::Login does for the web UI: a
# logincookies row plus the matching pair of cookies. These go in the cookie
# jar rather than on the request, because Mojo::UserAgent strips a Cookie
# header when it follows a redirect and buglist.cgi always redirects first.
sub login_as {
  my ($user) = @_;
  my $cookie = generate_random_password(16);
  $dbh->do(
    'INSERT INTO logincookies (cookie, userid, lastused) VALUES (?, ?, NOW())',
    undef, $cookie, $user->id);
  my $jar = $ua->cookie_jar;
  $jar->empty;
  $jar->add(
    map {
      Mojo::Cookie::Response->new(
        name   => $_->[0],
        value  => $_->[1],
        domain => $ua->server->url->host,
        path   => '/'
      )
    } ['Bugzilla_login', $user->id],
    ['Bugzilla_logincookie', $cookie]
  );
}

# One row per way of being refused: who asks, and the page they should get
# instead of the series. Anonymous is the report's headline case; the outsider
# covers the chartgroup gate (being logged in is not on its own permission to
# read a series); the charter covers the creator/is_public check inside
# Bugzilla::Series, which is what a regression to the old raw primary-key
# lookup would reopen for every charting user. Asserting the page each one
# lands on, and not just the absence of the marker, stops a 500 or the wrong
# error page from passing for a working gate.
for my $case (
  [undef,     qr{<div id="login-wrapper">}, 'anonymous'],
  [$outsider, qr/Authorization Required/,   'a user outside chartgroup'],
  [$charter,  qr/Invalid Series/, 'a chartgroup member who is not the creator'],
  )
{
  my ($user, $expect, $who) = @$case;
  $user ? login_as($user) : $ua->cookie_jar->empty;
  $t->get_ok($url)->status_is(200)->content_like($expect, "$who is refused");
  $t->content_unlike($secret_re, "$who does not leak the query");
}

# The owner still gets their own series, so the fix is a gate and not a
# removal of the feature. This also keeps the checks above honest: without it
# they would still pass if runseries were broken outright.
login_as($owner);
$t->get_ok($url)->status_is(200)
  ->content_like($secret_re, 'the series creator can still run it');

done_testing;
