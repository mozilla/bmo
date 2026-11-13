# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot::Client;

# The HTTP side of talking to the Hackbot API, and nothing else: no caching,
# no shaping of the data. Every request goes through _get(), so changing how
# BMO authenticates (e.g. a Google ID token instead of X-API-Key) is a change
# in one place.

use 5.10.1;
use strict;
use warnings;

use Bugzilla;
use Bugzilla::Extension::Hackbot::Constants;

use JSON qw(decode_json);
use LWP::UserAgent;

sub new {
  my ($class, %args) = @_;
  my $self = bless {
    base_url => $args{base_url} // Bugzilla->params->{hackbot_api_url},
    api_key  => $args{api_key}  // Bugzilla->params->{hackbot_api_key},
    ua       => $args{ua},
  }, $class;
  $self->{ua} //= $self->_build_ua;
  return $self;
}

# Fetch the runs recorded for a bug, newest first. Pass the ETag from a cached
# copy to make the request conditional.
#
# Returns a hashref:
#   {ok => 1, not_modified => 1, etag => ...}          - 304, cache is current
#   {ok => 1, not_modified => 0, etag => ..., runs => [...]}
#   {ok => 0, status => <http code>, errmsg => ...}
sub bug_runs {
  my ($self, $bug_id, $etag) = @_;

  return {ok => 0, status => 0, errmsg => 'hackbot_api_url is not set'}
    unless $self->{base_url};

  # $bug_id is a validated integer; the base URL ends in a slash (check_urlbase).
  my $url
    = $self->{base_url}
    . 'runs?bug_id='
    . int($bug_id)
    . '&limit='
    . HACKBOT_MAX_RUNS;

  my $result = $self->_get($url, $etag);
  return $result if !$result->{ok} || $result->{not_modified};

  unless (ref $result->{data} eq 'ARRAY') {
    return {
      ok     => 0,
      status => $result->{status},
      errmsg => 'response is not a list'
    };
  }

  return {
    ok           => 1,
    not_modified => 0,
    etag         => $result->{etag},
    runs         => $result->{data},
  };
}

sub _get {
  my ($self, $url, $etag) = @_;

  my @headers = ('Accept' => 'application/json');
  push @headers, ('X-API-Key'     => $self->{api_key}) if $self->{api_key};
  push @headers, ('If-None-Match' => $etag)            if defined $etag;

  my $response = $self->{ua}->get($url, @headers);

  # LWP counts a 304 as a failure, but for a conditional request it means the
  # cached copy is still valid. Keep the ETag the server echoes, if any.
  if ($response->code == 304) {
    return {ok => 1, not_modified => 1, etag => $response->header('ETag') // $etag};
  }

  unless ($response->is_success) {
    return {ok => 0, status => $response->code, errmsg => $response->status_line};
  }

  my $data = eval { decode_json($response->decoded_content) };
  if ($@) {
    return {ok => 0, status => $response->code, errmsg => "JSON parse error: $@"};
  }

  return {
    ok     => 1,
    status => $response->code,
    etag   => $response->header('ETag'),
    data   => $data,
  };
}

sub _build_ua {
  my $ua = LWP::UserAgent->new(timeout => HACKBOT_API_TIMEOUT);
  $ua->agent('BMO-Bugzilla/1.0');
  if (my $proxy = Bugzilla->params->{proxy_url}) {
    $ua->proxy('https', $proxy);
  }
  return $ua;
}

1;
