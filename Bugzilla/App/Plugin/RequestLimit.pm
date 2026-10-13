# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Plugin::RequestLimit;
use 5.10.1;
use Mojo::Base 'Mojolicious::Plugin';

use Bugzilla::Constants qw(
  USAGE_MODE_MOJO
  USAGE_MODE_MOJO_REST
);
use Bugzilla::Logging;

use constant REQUEST_TOO_LARGE_ERROR   => 'request_too_large';
use constant REQUEST_TOO_LARGE_MESSAGE => 'The request is too large.';

my %BODY_LIMIT_REASONS = map { $_ => 1 } (
  'Maximum message size exceeded',
  'Maximum buffer size exceeded',
);

my %KNOWN_NON_BODY_LIMIT_REASONS = map { $_ => 1 } (
  'Maximum start-line size exceeded',
  'Maximum header size exceeded',
);

sub register {
  my ($self, $app, $conf) = @_;
  $app->hook(around_action => \&_around_action);
}

sub _around_action {
  my ($next, $c, $action, $is_endpoint) = @_;
  return $next->() unless $is_endpoint;
  return $next->() if $c->isa('Bugzilla::App::Controller::CGI');

  my $format = $c->stash->{request_limit_format} // 'html';
  my $reason = request_limit_reason($c->req, $format eq 'rest');
  return $next->() unless defined $reason;

  my $route = $c->match->endpoint->to_string;
  WARN("Rejected oversized request for $route: $reason");

  if ($format eq 'rest') {
    Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
    return $c->user_error(REQUEST_TOO_LARGE_ERROR);
  }
  elsif ($format eq 'json') {
    return $c->render(
      json   => {error => REQUEST_TOO_LARGE_MESSAGE},
      status => 413
    );
  }
  elsif ($format eq 'empty') {
    return $c->render(data => '', status => 413);
  }

  Bugzilla->usage_mode(USAGE_MODE_MOJO);
  return $c->user_error(
    REQUEST_TOO_LARGE_ERROR,
    {},
    {status => 413, skip_exception_page => 1}
  );
}

sub request_limit_reason {
  my ($request, $is_rest) = @_;
  return undef unless $request->is_limit_exceeded;

  my $error = $request->error;
  return 'Unrecognized parser limit' unless ref $error eq 'HASH';

  my $reason = $error->{message} // '';
  return undef if $KNOWN_NON_BODY_LIMIT_REASONS{$reason} && !$is_rest;
  return $reason if $KNOWN_NON_BODY_LIMIT_REASONS{$reason};
  return $BODY_LIMIT_REASONS{$reason} ? $reason : 'Unrecognized parser limit';
}

1;
