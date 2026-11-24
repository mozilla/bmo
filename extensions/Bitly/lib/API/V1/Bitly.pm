# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Bitly::API::V1::Bitly;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::CGI;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Search;
use Bugzilla::Search::Quicksearch;
use Bugzilla::Util qw(mojo_user_agent);
use Bugzilla::API::V1::Util qw(render_options);
use URI;
use URI::QueryParam;

sub setup_routes {
  my ($class, $r) = @_;
  $r->get('/bitly/shorten')->to('Bitly::API::V1::Bitly#shorten');
  $r->get('/bitly/list')->to('Bitly::API::V1::Bitly#list');
  $r->options($_)->to(cb => \&render_options, allow => 'GET')
    foreach qw(/bitly/shorten /bitly/list);
}

# GET /bitly/shorten?url=<buglist.cgi URL>
#
# Shortens a buglist URL of this Bugzilla, without its user-specific list_id.
# Returns {url}.
sub shorten {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  $self->bugzilla->login;

  my $uri = $self->_validate_uri;
  $uri->query_param_delete('list_id');

  return $self->render(json => $self->_bitly($uri));
}

# GET /bitly/list?url=<buglist.cgi URL>
#
# Runs the search and shortens a buglist URL of the matching bug IDs, so the
# link shows the same bugs whoever opens it. Returns {url}.
sub list {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  $self->bugzilla->login;

  my $uri = $self->_validate_uri;

  # map params to cgi vars, converting quicksearch if required
  my $params
    = $uri->query_param('quicksearch')
    ? Bugzilla::CGI->new(quicksearch($uri->query_param('quicksearch')))->Vars
    : Bugzilla::CGI->new($uri->query)->Vars;

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

  return $self->render(json => $self->_bitly($uri));
}

# Only buglist queries of this Bugzilla can be shortened.
sub _validate_uri {
  my ($self) = @_;

  my $url = $self->every_param('url')->[0];
  defined $url
    || ThrowCodeError('param_required',
    {function => 'Bitly.shorten', param => 'url'});

  my $uri = URI->new($url);
  $uri->query(undef);
  $uri->fragment(undef);
  if ($uri->as_string ne Bugzilla->localconfig->urlbase . 'buglist.cgi') {
    ThrowUserError('bitly_unsupported');
  }

  return URI->new($url);
}

sub _bitly {
  my ($self, $uri) = @_;

  my $response
    = mojo_user_agent()
    ->post('https://api-ssl.bitly.com/v4/shorten' =>
      {'Authorization' => 'Bearer ' . Bugzilla->params->{bitly_token}} => json =>
      {long_url        => $uri->as_string})
    ->result;
  if (!$response->is_success) {
    ThrowUserError('bitly_failure', {message => $response->message});
  }

  return {url => $response->json->{link}};
}

1;
