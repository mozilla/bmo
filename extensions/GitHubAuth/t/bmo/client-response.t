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
use Try::Tiny;

use Bugzilla;
BEGIN { Bugzilla->extensions }

use_ok('Bugzilla::Extension::GitHubAuth::Client');
use_ok('Bugzilla::Extension::GitHubAuth::Client::Error');

# Fake user agent that returns a canned response for any request.
package FakeUA {
  sub new { my ($class, $response) = @_; bless {response => $response}, $class }
  sub get  { $_[0]->{response} }
  sub post { $_[0]->{response} }
}

$Bugzilla::Extension::GitHubAuth::Client::Error::USE_EXCEPTION_OBJECTS = 1;

sub response {
  my ($code, $content_type, $body, %headers) = @_;
  my $res = HTTP::Response->new($code, undef,
    ['Content-Type' => $content_type, %headers], $body);
  return $res;
}

sub client_with {
  my ($res) = @_;
  my $client = Bugzilla::Extension::GitHubAuth::Client->new;
  $client->{user_agent} = FakeUA->new($res);
  return $client;
}

sub error_from {
  my ($code) = @_;
  return try { $code->(); undef } catch { $_ };
}

subtest 'successful JSON responses are returned' => sub {
  my $client = client_with(response(
    200, 'application/json', '{"access_token":"abc","token_type":"bearer"}'
  ));
  is($client->get_access_token('code'), 'abc', 'access token returned');

  $client = client_with(response(
    200, 'application/json', '[{"email":"a@example.com","verified":true}]'
  ));
  is_deeply(
    $client->get_user_emails('abc'),
    [{email => 'a@example.com', verified => 1}],
    'email list returned'
  );
};

subtest 'non-2xx HTML error page reports the HTTP status' => sub {
  my $client = client_with(
    response(403, 'text/html', '<html>Forbidden</html>'));
  my $e = error_from(sub { $client->get_user_emails('abc') });
  isa_ok($e, 'Bugzilla::Extension::GitHubAuth::Client::Error');
  is($e->error, 'github_error', 'github_error, not github_bad_response');
  is($e->vars->{response}->code, 403, 'response attached to error');
};

subtest 'LWP internal failure reports a connection problem' => sub {
  my $client = client_with(response(
    500, 'text/plain', "Can't connect to github.com:443",
    'Client-Warning' => 'Internal response'
  ));
  my $e = error_from(sub { $client->get_access_token('code') });
  is($e->error, 'github_error', 'github_error thrown');
  is($e->vars->{response}->header('Client-Warning'),
    'Internal response', 'internal response marker preserved');
};

subtest '200 with non-JSON body reports status and content type' => sub {
  my $client = client_with(
    response(200, 'text/html', '<html>not json</html>'));
  my $e = error_from(sub { $client->get_access_token('code') });
  is($e->error,           'github_bad_response', 'github_bad_response');
  is($e->vars->{reason},  'Unable to parse JSON response', 'reason set');
  like($e->vars->{status}, qr/^200\b/, 'status line included');
  is($e->vars->{content_type}, 'text/html', 'content type included');
  ok(!exists $e->vars->{message}, 'no "message" var to collide with header');
};

subtest 'OAuth error payload is surfaced' => sub {
  my $client = client_with(response(
    200, 'application/json',
    '{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}'
  ));
  my $e = error_from(sub { $client->get_access_token('code') });
  is($e->error, 'github_bad_response', 'github_bad_response');
  is(
    $e->vars->{reason},
    'The code passed is incorrect or expired.',
    'GitHub error_description used as reason'
  );
};

subtest 'error page renders the GitHub error details' => sub {
  my $template = Bugzilla->template;
  my $output   = '';
  $template->process(
    'global/code-error.html.tmpl',
    {
      error        => 'github_bad_response',
      reason       => 'Unable to parse JSON response',
      status       => '200 OK',
      content_type => 'text/html',
    },
    \$output
  ) or diag($template->error);
  like($output, qr/Unable to parse JSON response/, 'reason rendered');
  like($output, qr/HTTP 200 OK, text\/html/,       'status rendered');
};

done_testing;
