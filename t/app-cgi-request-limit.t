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
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
  $ENV{LOG4PERL_CONFIG_FILE} = 'log4perl-t.conf';
  $ENV{MOJO_MAX_BUFFER_SIZE} = 64;
  $ENV{MOJO_MAX_MESSAGE_SIZE} = 512;
}

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;

use Test2::V0;
use Test::Mojo;

{
  package TestRequest;

  sub new {
    my ($class, $message, $is_limit_exceeded) = @_;
    return bless {
      message           => $message,
      is_limit_exceeded => $is_limit_exceeded // 1
    }, $class;
  }

  sub error {
    my ($self) = @_;
    return {message => $self->{message}};
  }

  sub is_limit_exceeded {
    my ($self) = @_;
    return $self->{is_limit_exceeded};
  }
}

{
  package TestRequestLimit;

  our $LIMIT_NEXT_HEADER = 0;

  sub lower_next_header_limit {
    my ($tx) = @_;
    return unless $LIMIT_NEXT_HEADER;
    $LIMIT_NEXT_HEADER = 0;
    my $request = $tx->req;
    my $headers = $request->headers;
    $headers->max_line_size(256);
  }
}

my $boundary = 'bugzilla-request-limit';
my $body = join(
  "\r\n",
  "--$boundary",
  'Content-Disposition: form-data; name="bug_type"',
  '',
  'defect',
  "--$boundary",
  'Content-Disposition: form-data; name="data"; filename="large.txt"',
  'Content-Type: text/plain',
  '',
  'x' x 512,
  "--$boundary--",
  ''
);
my $small_body = join(
  "\r\n",
  "--$boundary",
  'Content-Disposition: form-data; name="bug_type"',
  '',
  'defect',
  "--$boundary--",
  ''
);

my $t = Test::Mojo->new('Bugzilla::App');
# The request-size environment limit also applies to the client's responses.
$t->ua->max_response_size(0);

my $native_json_dispatched = 0;
my $native_json_route = $t->app->routes->post('/_test/native-json-limit');
$native_json_route->to(
  request_limit_format => 'json',
  cb                   => sub {
    my ($c) = @_;
    $native_json_dispatched++;
    return $c->render(json => {sentinel => 'controller ran'});
  }
);

$t->post_ok(
  '/_test/native-json-limit' => {'Content-Type' => 'application/json'} => '{}'
);
$t->status_is(200);
$t->json_is('/sentinel' => 'controller ran');
is($native_json_dispatched, 1, 'under-limit native JSON request dispatches');

$native_json_dispatched = 0;
$t->post_ok(
  '/_test/native-json-limit' => {'Content-Type' => 'application/json'} =>
    '{"data":"' . ('x' x 512) . '"}'
);
$t->status_is(413);
$t->header_like('Content-Type' => qr{^application/json\b});
$t->json_is('/error' => 'The request is too large.');
$t->content_unlike(qr{controller ran});
is($native_json_dispatched, 0, 'oversized native JSON request does not dispatch');

$t->post_ok(
  '/csp_report' => {'Content-Type' => 'application/csp-report'} => 'x' x 512
)->status_is(413)
  ->content_is('');

$t->post_ok(
  '/post_bug.cgi' => {
    'Content-Length' => length($small_body),
    'Content-Type'   => "multipart/form-data; boundary=$boundary",
  } => $small_body
)->status_is(200);

$t->post_ok(
  '/index.cgi' => {
    'Content-Length' => 128,
    'Content-Type'   => "multipart/form-data; boundary=$boundary",
  } => 'x' x 128
)->status_is(413)
  ->content_like(qr{The request is too large\.});

$t->post_ok(
  '/post_bug.cgi' => {
    'Content-Length' => length($body),
    'Content-Type'   => "multipart/form-data; boundary=$boundary",
  } => $body
)->status_is(413)
  ->header_like('Content-Type' => qr{^text/html\b})
  ->content_like(qr{<h1>Request Too Large</h1>})
  ->content_like(qr{The request is too large\.})
  ->content_unlike(qr{<h1>Bug Type Required</h1>});

$t->post_ok(
  '/index.cgi' => {
    'Content-Length' => length($body),
    'Content-Type'   => "multipart/form-data; boundary=$boundary",
  } => $body
)->status_is(413)
  ->content_like(qr{The request is too large\.});

$t->post_ok(
  '/rest/bug' => {
    'Content-Length' => length($body),
    'Content-Type'   => "multipart/form-data; boundary=$boundary",
  } => $body
)->status_is(413)
  ->header_like('Content-Type' => qr{^application/json\b})
  ->header_is('Access-Control-Allow-Origin' => '*')
  ->header_like(
    'Access-Control-Allow-Headers' => qr{\bauthorization\b}
  )
  ->header_like(
    'Access-Control-Allow-Headers' => qr{\bx-bugzilla-api-key\b}
  )
  ->header_like(
    'Access-Control-Allow-Headers' => qr{\bx-bugzilla-login\b}
  )
  ->json_is('/error' => 1)
  ->json_is('/code' => 58)
  ->json_is('/message' => 'The request is too large.');

$t->post_ok(
  '/rest/component/Test' => {
    'Content-Length' => 2,
    'Content-Type'   => 'application/json',
  } => '{}'
)->status_is(401)
  ->json_is('/code' => 410);

$t->post_ok(
  '/rest/component/Test' => {
    'Content-Length' => length($body),
    'Content-Type'   => 'application/json',
  } => $body
)->status_is(413)
  ->header_like('Content-Type' => qr{^application/json\b})
  ->header_is('Access-Control-Allow-Origin' => '*')
  ->header_like(
    'Access-Control-Allow-Headers' => qr{\bauthorization\b}
  )
  ->header_unlike(
    'Access-Control-Allow-Headers' => qr{\bx-bugzilla-login\b}
  )
  ->json_is('/error' => 1)
  ->json_is('/code' => 58)
  ->json_is('/message' => 'The request is too large.');

$TestRequestLimit::LIMIT_NEXT_HEADER = 1;
my $app = $t->app;
$app->hook(after_build_tx => \&TestRequestLimit::lower_next_header_limit);
$t->post_ok(
  '/rest/component/Test' => {
    'Content-Length'       => 2,
    'Content-Type'         => 'application/json',
    'X-Over-Limit-Header'  => 'x' x 256,
  } => '{}'
);
$t->status_is(413);
$t->header_like('Content-Type' => qr{^application/json\b});
$t->header_is('Access-Control-Allow-Origin' => '*');
$t->json_is('/error' => 1);
$t->json_is('/code' => 58);
$t->json_is('/message' => 'The request is too large.');

for my $reason (
  'Maximum message size exceeded',
  'Maximum buffer size exceeded'
) {
  is(
    Bugzilla::App::Plugin::RequestLimit::request_limit_reason(
      TestRequest->new($reason)
    ),
    $reason,
    "$reason is rejected before native action dispatch"
  );
}

for my $reason ('Maximum header size exceeded', 'Maximum start-line size exceeded') {
  is(
    Bugzilla::App::Plugin::RequestLimit::request_limit_reason(
      TestRequest->new($reason)
    ),
    undef,
    "$reason preserves fallback behavior"
  );
  is(
    Bugzilla::App::Plugin::RequestLimit::request_limit_reason(
      TestRequest->new($reason),
      1
    ),
    $reason,
    "$reason remains rejected for REST"
  );
}

is(
  Bugzilla::App::Plugin::RequestLimit::request_limit_reason(
    TestRequest->new('A future Mojolicious limit error')
  ),
  'Unrecognized parser limit',
  'unknown parser limits are rejected safely'
);

is(
  Bugzilla::App::Plugin::RequestLimit::request_limit_reason(
    TestRequest->new('Unrelated parser error', 0)
  ),
  undef,
  'non-limit parser errors retain fallback behavior'
);

$t->app->routes->get('/_test/status-error')->to(
  cb => sub {
    my ($c) = @_;
    Bugzilla->usage_mode(Bugzilla::Constants::USAGE_MODE_MOJO);
    return $c->user_error('request_too_large', {}, {status => 413});
  }
);
$t->get_ok('/_test/status-error')
  ->status_is(500)
  ->content_like(qr{<title>Server Error \(development mode\)</title>});

done_testing;
