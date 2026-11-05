# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Bitly::WebService;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::WebService);

use Bugzilla::CGI;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Search;
use Bugzilla::Search::Quicksearch;
use Bugzilla::Util qw(mojo_user_agent);
use Bugzilla::API::V1::Util qw(validate);
use JSON;
use LWP::UserAgent;
use URI;
use URI::Escape;
use URI::QueryParam;

use constant PUBLIC_METHODS => qw(
  list
  shorten
);

sub _validate_uri {
  my ($self, $params) = @_;

  # extract URL from params
  if (!defined $params->{url}) {
    ThrowCodeError('param_required', {function => 'Bitly.shorten', param => 'url'});
  }
  my $url = ref($params->{url}) ? $params->{url}->[0] : $params->{url};

  # only allow buglist queries for this Bugzilla install
  my $uri = URI->new($url);
  $uri->query(undef);
  $uri->fragment(undef);
  if ($uri->as_string ne Bugzilla->localconfig->urlbase . 'buglist.cgi') {
    ThrowUserError('bitly_unsupported');
  }

  return URI->new($url);
}

sub shorten {
  my ($self) = shift;
  my $uri = $self->_validate_uri(@_);

  # the list_id is user-specific, remove it
  $uri->query_param_delete('list_id');

  return $self->_bitly($uri);
}

sub list {
  my ($self) = shift;
  my $uri = $self->_validate_uri(@_);

  # map params to cgi vars, converting quicksearch if required
  my $params
    = $uri->query_param('quicksearch')
    ? Bugzilla::CGI->new(quicksearch($uri->query_param('quicksearch')))->Vars
    : Bugzilla::CGI->new($uri->query)->Vars;

  # execute the search
  my $search = Bugzilla::Search->new(
    params => $params,
    fields => ['bug_id'],
    limit  => Bugzilla->params->{max_search_results},
  );
  my $data = $search->data;

  # form a bug_id only URL, sanity check the length
  $uri
    = URI->new(Bugzilla->localconfig->urlbase
      . 'buglist.cgi?bug_id='
      . join(',', map { $_->[0] } @$data));
  if (length($uri->as_string) > CGI_URI_LIMIT) {
    ThrowUserError('bitly_failure',
      {message => "Too many bugs returned by search"});
  }

  # shorten
  return $self->_bitly($uri);
}

sub _bitly {
  my ($self, $uri) = @_;

  # Make the request
  my $ua = mojo_user_agent();
  my $response
    = $ua->post('https://api-ssl.bitly.com/v4/shorten' =>
      {'Authorization' => 'Bearer ' . Bugzilla->params->{bitly_token}} => json =>
      {long_url        => $uri->as_string})->result;
  if (!$response->is_success) {
    ThrowUserError('bitly_failure', {message => $response->message});
  }

  # return just the short URL
  return {url => $response->json->{link}};
}

sub rest_resources {
  return [
    qr{^/bitly/shorten$}, {GET => {method => 'shorten',},},
    qr{^/bitly/list$},    {GET => {method => 'list',},},
  ];
}

1;
