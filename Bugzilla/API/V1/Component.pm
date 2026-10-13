# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Component;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Mojo::JSON qw(false true);

use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::Util             qw(email_filter trim);
use Bugzilla::WebService::Util qw(merge_request_params);

sub setup_routes {
  my ($class, $r) = @_;
  my $comp_routes = $r->under(
    '/component' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });
  # /*product allows product names containing a /
  $comp_routes->post('/*product')->to('V1::Component#create');
  $comp_routes->post('/')->to('V1::Component#create');

  # /*component allows component names containing a /
  # Unfortunately when specifying a product and component together,
  # the product name cannot contain a / so you have to instead use
  # named parameters as described below.
  $comp_routes->put('/:product/*component')->to('V1::Component#update');
  $comp_routes->get('/:product/*component')->to('V1::Component#get');
  # Allow fallback route for use if product name contains a /
  # Must use named parameters such as ?product=Firefox&component=General
  $comp_routes->put('/')->to('V1::Component#update');
  $comp_routes->get('/')->to('V1::Component#get');
}

sub create {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  $user->in_group('editcomponents')
    || return $self->user_error('auth_failure',
    {group => 'editcomponents', action => 'add', object => 'components'});

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  my $product = Bugzilla::Product->check({name => $self->param('product')});

  # Check user related fields
  foreach my $field (qw(default_assignee default_qa_contact triage_owner)) {
    my $value = trim($params->{$field});
    next if !$value;
    my $field_user = Bugzilla::User->check({name => $value});

    # Triage owner value needs to be in the form of user id, not login
    $params->{$field} = $field_user->id if $field eq 'triage_owner';
  }

  my $create = {
    name                     => trim($params->{name}                     || ''),
    description              => trim($params->{description}              || ''),
    default_bug_type         => trim($params->{default_bug_type}         || ''),
    initialowner             => trim($params->{default_assignee}         || ''),
    initialqacontact         => trim($params->{default_qa_contact}       || ''),
    triage_owner_id          => trim($params->{triage_owner}             || ''),
    team_name                => trim($params->{team_name}                || ''),
    bug_description_template => trim($params->{bug_description_template} || ''),
    product                  => $product,
  };

  my $component = Bugzilla::Component->create($create);

  return $self->render(json => $self->_component_to_hash($component));
}

sub update {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  if (!$user->in_group('editcomponents') && !$user->in_group('edittriageowners'))
  {
    return $self->user_error('auth_failure',
      {group => 'editcomponents', action => 'modify', object => 'components'});
  }

  my $product   = Bugzilla::Product->check({name => $self->param('product')});
  my $component = Bugzilla::Component->check(
    {name => $self->param('component'), product => $product});

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  # Whitelist the documented update fields; set_all() throws unknown_method
  # for any stray key (e.g. Bugzilla_api_token, include_fields).
  my %values = map { $_ => $params->{$_} }
    grep { exists $params->{$_} }
    qw(name description default_assignee default_qa_contact default_bug_type
    is_active triage_owner team_name bug_description_template);

  # A JSON body sends is_active as a real boolean, but the query string and a
  # form body send the literal string "true" or "false", and check_boolean
  # treats any non-empty string as true.
  if (exists $values{is_active} && !ref $values{is_active}) {
    my $is_active = lc($values{is_active} // '');
    return $self->user_error('invalid_params',
      {type_error => 'is_active must be true or false'})
      if $is_active !~ /^(?:true|false|1|0)$/;
    $values{is_active} = ($is_active eq 'true' || $is_active eq '1') ? 1 : 0;
  }

  # If the user is only able to edit triage owner and nothing else,
  # then we only allow that field to be passed to set_all()
  if (!$user->in_group('editcomponents')) {
    %values = exists $values{triage_owner}
      ? (triage_owner => $values{triage_owner})
      : ();
  }

  $component->set_all(\%values);
  $component->update();

  return $self->render(json => $self->_component_to_hash($component));
}

sub get {
  my ($self) = @_;
  my $user = $self->bugzilla->login;

  my $product   = Bugzilla::Product->check({name => $self->param('product')});
  my $component = Bugzilla::Component->check(
    {name => $self->param('component'), product => $product});

  return $self->render(json => $self->_component_to_hash($component));
}

sub _component_to_hash {
  my ($self, $component) = @_;

  return {
    id                       => $component->id,
    name                     => $component->name,
    description              => $component->description,
    default_assignee         => $component->default_assignee->login,
    default_qa_contact       => $component->default_qa_contact->login,
    triage_owner             => $component->triage_owner->login,
    is_active                => $component->is_active ? true : false,
    default_bug_type         => $component->default_bug_type,
    team_name                => $component->team_name,
    bug_description_template => $component->bug_description_template,
  };
}

1;
