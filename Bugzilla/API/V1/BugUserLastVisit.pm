# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::BugUserLastVisit;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Util             qw(datetime_from);
use Bugzilla::WebService::Util qw(filter merge_request_params);

sub setup_routes {
  my ($class, $r) = @_;
  my $routes = $r->under(
    '/bug_user_last_visit' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });
  $routes->get('/')->to('V1::BugUserLastVisit#get');
  $routes->get('/:id' => [id => qr/\d+/])->to('V1::BugUserLastVisit#get');
  $routes->post('/')->to('V1::BugUserLastVisit#update');
  $routes->post('/:id' => [id => qr/\d+/])->to('V1::BugUserLastVisit#update');

  $routes->options('/')->to('V1::BugUserLastVisit#options');
  $routes->options('/:id' => [id => qr/\d+/])
    ->to('V1::BugUserLastVisit#options');
}

sub options {
  my ($self) = @_;

  $self->res->headers->header('Allow'                        => 'GET, POST');
  $self->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST');

  return $self->rendered(200);
}

sub get {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $params_error) = $self->_request_params;
  return $self->user_error($params_error) if $params_error;

  my ($ids, $error, $vars) = $self->_ids_from_request($params);
  return $self->user_error($error, $vars) if $error;

  if ($ids) {

    # Cache permissions for bugs. This highly reduces the number of calls to
    # the DB.  visible_bugs() is only able to handle bug IDs, so we have to
    # skip aliases.
    $user->visible_bugs([grep {/^[0-9]+$/} @$ids]);
  }

  my @last_visits = @{$user->last_visited};

  if ($ids) {

    # remove bugs that we are not interested in if ids is passed in.
    my %id_set = map { ($_ => 1) } @$ids;
    @last_visits = grep { $id_set{$_->bug_id} } @last_visits;
  }

  return $self->render(
    json => [
      map {
        $self->_bug_user_last_visit_to_hash($_->bug_id, $_->last_visit_ts, $params)
      } @last_visits
    ]
  );
}

sub update {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $params_error) = $self->_request_params;
  return $self->user_error($params_error) if $params_error;

  my ($ids, $error, $vars) = $self->_ids_from_request($params);
  return $self->user_error($error, $vars) if $error;
  return $self->code_error('param_required', {param => 'ids'})
    unless $ids && @$ids;

  # Cache permissions for bugs. This highly reduces the number of calls to the
  # DB.  visible_bugs() is only able to handle bug IDs, so we have to skip
  # aliases.
  $user->visible_bugs([grep {/^[0-9]+$/} @$ids]);

  my $dbh = Bugzilla->dbh;

  $dbh->bz_start_transaction();
  my @results;
  my $last_visit_ts = $dbh->selectrow_array('SELECT NOW()');
  foreach my $bug_id (@$ids) {
    my $bug = Bugzilla::Bug->check({id => $bug_id, cache => 1});

    next unless $user->can_see_bug($bug->id);

    $bug->update_user_last_visit($user, $last_visit_ts);

    push(@results,
      $self->_bug_user_last_visit_to_hash($bug->id, $last_visit_ts, $params));
  }
  $dbh->bz_commit_transaction();

  return $self->render(json => \@results);
}

sub _ids_from_request {
  my ($self, $params) = @_;

  my $path_id = $self->stash('id');

  # Legacy REST layer (_retrieve_json_params in
  # Bugzilla::WebService::Server::REST): for GET, the path id wins over any
  # query-string ids. For POST, request-body/query-string params are merged
  # in *after* the path-derived params, so they win instead.
  if (defined $path_id && $self->req->method ne 'POST') {
    return [$path_id];
  }

  my $ids = $params->{ids};
  if (!defined $ids) {
    return defined $path_id ? [$path_id] : undef;
  }

  return (undef, 'invalid_params', {type_error => 'ids must be an array'})
    if ref $ids && ref $ids ne 'ARRAY';
  return ref $ids eq 'ARRAY' ? $ids : [$ids];
}

sub _request_params {
  my ($self) = @_;

  my ($params, $error) = merge_request_params($self, ['ids']);
  return (undef, $error) if $error;

  for my $field (qw(include_fields exclude_fields)) {
    $params->{$field} = [split(/[\s,]+/, $params->{$field})]
      if exists $params->{$field} && !ref $params->{$field};
  }

  return ($params, undef);
}

sub _bug_user_last_visit_to_hash {
  my ($self, $bug_id, $last_visit_ts, $params) = @_;

  return filter(
    $params,
    {
      id            => 0 + $bug_id,
      last_visit_ts => datetime_from($last_visit_ts, 'UTC')->iso8601() . 'Z',
    }
  );
}

1;

__END__

=head1 NAME

Bugzilla::API::V1::BugUserLastVisit - Find and Store the last time a user
visited a bug.

=head1 DESCRIPTION

This part of the Bugzilla REST API allows you to lookup and update the last
time a user visited a bug.
