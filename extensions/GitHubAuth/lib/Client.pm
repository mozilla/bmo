# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::GitHubAuth::Client;

use 5.10.1;
use strict;
use warnings;

use JSON qw(decode_json);
use LWP::UserAgent;
use URI;
use URI::QueryParam;
use Digest;

use Bugzilla::Extension::GitHubAuth::Client::Error
  qw(ThrowUserError ThrowCodeError);
use Bugzilla::Logging;
use Bugzilla::Util qw(remote_ip truncate_string);

use constant DIGEST_HASH => 'SHA1';

# How much of an unexpected response body to include in log messages.
use constant LOG_BODY_LENGTH => 500;

use fields qw(user_agent);

use constant {
  GH_ACCESS_TOKEN_URI => 'https://github.com/login/oauth/access_token',
  GH_AUTHORIZE_URI    => 'https://github.com/login/oauth/authorize',
  GH_USER_EMAILS_URI  => 'https://api.github.com/user/emails',
};

sub new {
  my ($class, %init) = @_;
  my $self = $class->fields::new();

  return $self;
}

sub authorize_uri {
  my ($class, $state) = @_;

  my $uri = URI->new(GH_AUTHORIZE_URI);
  $uri->query_form(
    client_id    => Bugzilla->params->{github_client_id},
    scope        => 'user:email',
    state        => $state,
    redirect_uri => Bugzilla->localconfig->urlbase . "github.cgi",
  );

  return $uri;
}

sub get_email_key {
  my ($class, $email) = @_;

  my $cgi    = Bugzilla->cgi;
  my $digest = Digest->new(DIGEST_HASH);
  $digest->add($email);
  $digest->add(remote_ip());
  $digest->add($cgi->cookie('Bugzilla_github_token')
      // Bugzilla->request_cache->{github_token} // '');
  $digest->add(Bugzilla->localconfig->site_wide_secret);
  return $digest->hexdigest;
}

sub _handle_response {
  my ($self, $response) = @_;

  # Check the status before parsing: error pages from GitHub, a proxy, or
  # LWP itself (internal 500s for DNS/TLS failures) are usually not JSON.
  unless ($response->is_success) {
    _log_bad_response('HTTP error', $response);
    ThrowCodeError("github_error", {response => $response});
  }

  my $data = eval { decode_json($response->decoded_content(charset => 'none') // ''); };
  if ($@) {
    my $reason = 'Unable to parse JSON response';
    _log_bad_response($reason, $response);
    ThrowCodeError(
      "github_bad_response",
      {
        reason       => $reason,
        status       => $response->status_line,
        content_type => scalar $response->header('Content-Type'),
      }
    );
  }

  # GitHub's token endpoint reports failures (e.g. bad_verification_code)
  # as a 200 response with an "error" key.
  if (ref $data eq 'HASH' && $data->{error}) {
    ThrowCodeError(
      "github_bad_response",
      {
        reason => $data->{error_description} || $data->{error},
        status => $response->status_line,
      }
    );
  }

  return $data;
}

# The error vars Bugzilla::Error logs don't include the response body (and
# github_error only carries the HTTP::Response object), so record enough of
# the response to diagnose GitHub failures from the logs alone.
sub _log_bad_response {
  my ($reason, $response) = @_;
  my $body
    = truncate_string($response->decoded_content // '', LOG_BODY_LENGTH, '...');
  WARN(sprintf(
    'GitHub %s: %s (%s) from %s: %s',
    $reason,
    $response->status_line,
    $response->header('Content-Type') // 'no content type',
    ($response->request ? $response->request->uri : 'unknown URI'),
    $body
  ));
}

sub get_access_token {
  my ($self, $code) = @_;

  my $response = $self->user_agent->post(GH_ACCESS_TOKEN_URI,
    {
      client_id     => Bugzilla->params->{github_client_id},
      client_secret => Bugzilla->params->{github_client_secret},
      code          => $code
    },
    Accept => 'application/json',
  );
  my $data = $self->_handle_response($response);
  return $data->{access_token} if exists $data->{access_token};
}

sub get_user_emails {
  my ($self, $access_token) = @_;

  my $response = $self->user_agent->get(GH_USER_EMAILS_URI,
    'Accept'        => 'application/json',
    'Authorization' => "token $access_token"
  );

  return $self->_handle_response($response);
}

sub user_agent {
  my ($self) = @_;
  $self->{user_agent} //= $self->_build_user_agent;

  return $self->{user_agent};
}

sub _build_user_agent {
  my ($self) = @_;
  my $ua = LWP::UserAgent->new(timeout => 10);

  if (Bugzilla->params->{proxy_url}) {
    $ua->proxy('https', Bugzilla->params->{proxy_url});
  }

  return $ua;
}

1;
