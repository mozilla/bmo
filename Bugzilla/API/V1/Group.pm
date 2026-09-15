# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Group;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Mojo::JSON qw(decode_json true false);
use Try::Tiny;

use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Group;
use Bugzilla::User;
use Bugzilla::WebService::Util qw(params_to_objects translate validate);

use constant MAPPED_RETURNS =>
  {userregexp => 'user_regexp', isactive => 'is_active'};

sub setup_routes {
  my ($class, $r) = @_;
  my $routes = $r->under(
    '/group' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });
  $routes->get('/')->to('V1::Group#get');
  $routes->get('/:id')->to('V1::Group#get');
  $routes->post('/')->to('V1::Group#create');
  $routes->put('/:id')->to('V1::Group#update');

  foreach my $path ('/', '/:id') {
    $routes->options($path)->to('V1::Group#options');
  }
}

sub options {
  my ($self) = @_;

  $self->res->headers->header('Allow'                        => 'GET, POST, PUT');
  $self->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT');

  return $self->rendered(200);
}

sub create {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');
  $user->in_group('creategroups')
    || return $self->user_error('auth_failure',
    {group => 'creategroups', action => 'add', object => 'groups'});

  my $params = $self->_request_params;

  my $group = Bugzilla::Group->create({
    name        => $params->{name},
    description => $params->{description},
    userregexp  => $params->{user_regexp},
    isactive    => $params->{is_active},
    isbuggroup  => 1,
    icon_url    => $params->{icon_url},
  });

  return $self->render(json => {id => 0 + $group->id}, status => 201);
}

sub update {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');
  $user->in_group('creategroups')
    || return $self->user_error('auth_failure',
    {group => 'creategroups', action => 'edit', object => 'groups'});

  my $params = $self->_request_params;
  if (defined(my $id_or_name = $self->param('id'))) {
    $params
      = $id_or_name =~ /^\d+$/
      ? {%$params, ids   => [$id_or_name], names => undef}
      : {%$params, names => [$id_or_name], ids   => undef};
  }

  defined($params->{names}) || defined($params->{ids})
    || return $self->code_error('params_required',
    {function => 'Group.update', params => ['ids', 'names']});

  my $group_objects = params_to_objects($params, 'Bugzilla::Group');

  # Some groups are protected from being edited by non-admins.
  foreach my $group (@$group_objects) {
    $group->check_can_be_edited();
  }

  my %values = %$params;
  delete $values{names};
  delete $values{ids};

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction();
  foreach my $group (@$group_objects) {
    $group->set_all(\%values);
  }

  my %changes;
  foreach my $group (@$group_objects) {
    my $returned_changes = $group->update();
    $changes{$group->id} = translate($returned_changes, MAPPED_RETURNS);
  }
  $dbh->bz_commit_transaction();

  my @result;
  foreach my $group (@$group_objects) {
    my %hash = (id => 0 + $group->id, changes => {});
    foreach my $field (keys %{$changes{$group->id}}) {
      my $change = $changes{$group->id}->{$field};
      $hash{changes}{$field}
        = {removed => "$change->[0]", added => "$change->[1]"};
    }
    push(@result, \%hash);
  }

  return $self->render(json => {groups => \@result});
}

sub get {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my $params = $self->_request_params;
  if (defined(my $id_or_name = $self->param('id'))) {
    $params
      = $id_or_name =~ /^\d+$/
      ? {%$params, ids   => [$id_or_name]}
      : {%$params, names => [$id_or_name]};
  }
  (undef, $params) = validate($self, $params, qw(ids names type));

  my $can_see_groups = $user->in_group('can_see_groups');
  return $self->user_error('group_cannot_view')
    if !$can_see_groups && !$user->can_bless;

  Bugzilla->switch_to_shadow_db();

  my $groups = [];

  if (defined $params->{ids}) {

    # Get the groups by id
    $groups = Bugzilla::Group->new_from_list($params->{ids});
  }

  if (defined $params->{names}) {

    # Get the groups by name. check() will throw an error if a bad name is
    # given.
    foreach my $name (@{$params->{names}}) {

      # Skip if we got this from params->{ids}
      next if grep { $_->name eq $name } @$groups;

      push @$groups, Bugzilla::Group->check({name => $name});
    }
  }

  if (!defined $params->{ids} && !defined $params->{names}) {
    if ($can_see_groups) {
      @$groups = Bugzilla::Group->get_all;
    }
    else {
      # Get only groups the user has bless privileges for.
      $groups = $user->bless_groups;
    }
  }

  # Filter groups by blessability if user is not allowed to see all groups.
  # NOTE: this mirrors a pre-existing quirk in the legacy WebService
  # implementation: $user->can_bless() expects a group id, not a Group
  # object, so this filter is a no-op that leaves $groups untouched in
  # practice rather than actually filtering by blessability.
  if (!$can_see_groups) {
    $groups = [map { $user->can_bless($_) } @{$groups}];
  }

  my @result = map { $self->_group_to_hash($params, $_) } @$groups;

  return $self->render(json => {groups => \@result});
}

sub _group_to_hash {
  my ($self, $params, $group) = @_;
  my $user = Bugzilla->user;

  my $field_data
    = {id => 0 + $group->id, name => $group->name, description => $group->description};

  if ($user->in_group('creategroups')) {
    $field_data->{is_active}    = $group->is_active    ? true : false;
    $field_data->{is_bug_group} = $group->is_bug_group ? true : false;
    $field_data->{user_regexp}  = $group->user_regexp;
  }

  if ($params->{membership}) {
    $field_data->{membership} = $self->_get_group_membership($group);
  }

  return $field_data;
}

sub _get_group_membership {
  my ($self, $group) = @_;
  my $user = Bugzilla->user;

  my $dbh       = Bugzilla->dbh;
  my $editusers = $user->in_group('editusers');

  my $query = 'SELECT userid FROM profiles';
  my $visible_groups;

  if (!$editusers && Bugzilla->params->{usevisibilitygroups}) {

    # Show only users in visible groups.
    $visible_groups = $user->visible_groups_inherited;

    if (scalar @$visible_groups) {
      $query .= qq{, user_group_map AS ugm
                         WHERE ugm.user_id = profiles.userid
                           AND ugm.isbless = 0
                           AND } . $dbh->sql_in('ugm.group_id', $visible_groups);
    }
  }
  elsif ($editusers
    || $user->can_bless($group->id)
    || $user->in_group('creategroups'))
  {
    $visible_groups = 1;
    $query .= qq{, user_group_map AS ugm
                     WHERE ugm.user_id = profiles.userid
                       AND ugm.isbless = 0
                    };
  }

  # Use ThrowUserError (not $self->user_error) so an invisible group aborts
  # the request cleanly even though this runs nested inside the map() in
  # get() -- returning a rendered response from here would leave get()'s
  # own render() call to fire a second time.
  ThrowUserError('group_not_visible', {group => $group}) unless $visible_groups;

  my $grouplist = Bugzilla::Group->flatten_group_membership($group->id);
  $query .= ' AND ' . $dbh->sql_in('ugm.group_id', $grouplist);

  my $userids      = $dbh->selectcol_arrayref($query);
  my $user_objects = Bugzilla::User->new_from_list($userids);

  return [
    map {
      {
        id                => 0 + $_->id,
        real_name         => $_->name,
        nick              => $_->nick,
        name              => $_->login,
        email             => $_->email,
        can_login         => $_->is_enabled     ? true : false,
        email_enabled     => $_->email_enabled  ? true : false,
        login_denied_text => $_->disabledtext,
      }
    } @$user_objects
  ];
}

sub _request_params {
  my ($self) = @_;

  # $self->req->params already covers the query string plus, for POST/PUT,
  # an application/x-www-form-urlencoded or multipart body. Layer a JSON
  # body underneath that (silently ignored if absent or not valid JSON) so
  # params work from either the query string or a JSON request body.
  # Query-string values win on a key collision, matching the legacy REST
  # layer and the documented behavior in docs/en/rst/api/core/v1/general.rst.
  my $params = $self->req->params->to_hash;

  if (length $self->req->body) {
    my $body_params;
    try { $body_params = decode_json($self->req->body); }
    catch { $body_params = undef; };
    $params = {%$body_params, %$params} if ref $body_params eq 'HASH';
  }

  return $params;
}

1;

__END__

=head1 NAME

Bugzilla::API::V1::Group - The API for creating, changing, and getting
information about Groups.

=head1 DESCRIPTION

This part of the Bugzilla API allows you to create Groups and get
information about them. See L<docs/en/rst/api/core/v1/group.rst> for the
public REST documentation.
