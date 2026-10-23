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
use Bugzilla::Test::MockParams (log_user_requests => 1);
use Bugzilla::Test::Util qw(create_user issue_api_key);

use Bugzilla::Constants;
use Test2::V0;
use Test::Mojo;

# Native Mojo API routes have no emulated CGI environment, so
# Bugzilla->log_user_request must read the request from the Mojo controller.

my $user = create_user('logged@mozilla.org', '*');
my $key  = issue_api_key('logged@mozilla.org');

my $t = Test::Mojo->new('Bugzilla::App');
$t->app->routes->get(
  '/test/log_user_request' => sub {
    my $c = shift;
    Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
    $c->bugzilla->login;
    Bugzilla->log_user_request(42, 7, 'attachment-get');
    $c->render(json => {});
  }
);

# Like the legacy REQUEST_URI, the logged URL is the path without the query.
$t->get_ok('/test/log_user_request?ids=1' =>
    {'X-Bugzilla-API-Key' => $key->api_key, 'User-Agent' => 'log-test/1.0',})
  ->status_is(200);

my $rows = Bugzilla->dbh->selectall_arrayref(
  'SELECT user_id, user_agent, request_url, method, bug_id, attach_id,
          action, server
     FROM user_request_log', {Slice => {}}
);
is(
  $rows,
  [{
    user_id     => $user->id,
    user_agent  => 'log-test/1.0',
    request_url => '/test/log_user_request',
    method      => 'GET',
    bug_id      => 42,
    attach_id   => 7,
    action      => 'attachment-get',
    server      => 'rest',
  }],
  'The request is logged from the Mojo request'
);

done_testing;
