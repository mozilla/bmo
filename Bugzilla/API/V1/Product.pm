# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Product;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Mojo::JSON qw(true false);

use Bugzilla::Constants;
use Bugzilla::Product;
use Bugzilla::Util             qw(email_filter);
use Bugzilla::WebService::Util qw(filter filter_wants merge_request_params);

use constant FIELD_MAP =>
  {has_unconfirmed => 'allows_unconfirmed', is_open => 'isactive'};

sub setup_routes {
  my ($class, $r) = @_;
  my $routes = $r->under(
    '/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  foreach my $type (qw(accessible enterable selectable)) {
    $routes->get("/product_$type")
      ->to('V1::Product#get_products_by_type', product_type => $type);
    $routes->options("/product_$type")
      ->to('V1::Product#options', allow => 'GET');
  }

  $routes->get('/product')->to('V1::Product#get');
  $routes->post('/product')->to('V1::Product#create');
  $routes->get('/product/#id_or_name')->to('V1::Product#get');

  $routes->options('/product')->to('V1::Product#options', allow => 'GET, POST');
  $routes->options('/product/#id_or_name')
    ->to('V1::Product#options', allow => 'GET');
}

sub options {
  my ($self) = @_;

  my $allow = $self->stash('allow');
  $self->res->headers->header('Allow'                        => $allow);
  $self->res->headers->header('Access-Control-Allow-Methods' => $allow);

  return $self->rendered(200);
}

# GET /product_accessible, /product_enterable and /product_selectable: the ids
# of the products the user can search and/or enter bugs against.
sub get_products_by_type {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  my $method = 'get_' . $self->stash('product_type') . '_products';

  Bugzilla->switch_to_shadow_db();
  return $self->render(json => {ids => [map { 0 + $_->id } @{$user->$method}]});
}

# Get a list of actual products, based on list of ids or names
our %FLAG_CACHE;

sub get {
  my ($self) = @_;

  my $user = $self->bugzilla->login;

  my @list_params = qw(ids names type include_fields exclude_fields);
  my ($params, $error) = merge_request_params($self, \@list_params);
  return $self->user_error($error) if $error;

  # A JSON body is merged in as-is, so a single value there is not yet a list;
  # legacy validate() coerced it the same way.
  for my $field (@list_params) {
    $params->{$field} = [$params->{$field}]
      if defined $params->{$field} && !ref $params->{$field};
  }

  for my $field (qw(include_fields exclude_fields)) {
    $params->{$field} = [map { split(/[\s,]+/) } @{$params->{$field}}]
      if exists $params->{$field};
  }

  if (defined(my $id_or_name = $self->stash('id_or_name'))) {
    $params->{$id_or_name =~ /^\d+$/ ? 'ids' : 'names'} = [$id_or_name];
  }

       defined $params->{ids}
    || defined $params->{names}
    || defined $params->{type}
    || return $self->code_error('params_required',
    {function => 'Product.get', params => ['ids', 'names', 'type']});

  Bugzilla->switch_to_shadow_db();

  my $products = [];
  if (defined $params->{type}) {
    my %product_hash;
    foreach my $type (@{$params->{type}}) {
      my $result = [];
      if ($type eq 'accessible') {
        $result = $user->get_accessible_products();
      }
      elsif ($type eq 'enterable') {
        $result = $user->get_enterable_products();
      }
      elsif ($type eq 'selectable') {
        $result = $user->get_selectable_products();
      }
      else {
        return $self->user_error('get_products_invalid_type', {type => $type});
      }
      map { $product_hash{$_->id} = $_ } @$result;
    }
    $products = [values %product_hash];
  }
  else {
    $products = $user->get_accessible_products;
  }

  my @requested_products;

  if (defined $params->{ids}) {

    # Create a hash with the ids the user wants
    my %ids = map { $_ => 1 } @{$params->{ids}};

    # Return the intersection of this, by grepping the ids from
    # accessible products.
    push(@requested_products, grep { $ids{$_->id} } @$products);
  }

  if (defined $params->{names}) {

    # Create a hash with the names the user wants
    my %names = map { lc($_) => 1 } @{$params->{names}};

    # Return the intersection of this, by grepping the names from
    # accessible products, union'ed with products found by ID to
    # avoid duplicates
    foreach my $product (grep { $names{lc $_->name} } @$products) {
      next if grep { $_->id == $product->id } @requested_products;
      push @requested_products, $product;
    }
  }

  # If we just requested a specific type of products without
  # specifying ids or names, then return the entire list.
  if (!defined $params->{ids} && !defined $params->{names}) {
    @requested_products = @$products;
  }

  # Now create a result entry for each.
  local %FLAG_CACHE = ();
  my @products = map { $self->_product_to_hash($params, $_) } @requested_products;
  return $self->render(json => {products => \@products});
}

sub create {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');
  $user->in_group('editcomponents')
    || return $self->user_error('auth_failure',
    {group => 'editcomponents', action => 'add', object => 'products'});

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  # A JSON body sends booleans as real booleans, but the query string and a
  # form body send the literal string "true" or "false", which Perl treats as
  # true either way.
  foreach my $field (qw(has_unconfirmed is_open create_series)) {
    next if !defined $params->{$field} || ref $params->{$field};
    my $value = lc $params->{$field};
    return $self->user_error('invalid_params',
      {type_error => "$field must be true or false"})
      if $value !~ /^(?:true|false|1|0)$/;
    $params->{$field} = ($value eq 'true' || $value eq '1') ? 1 : 0;
  }

  # Create product
  my $args = {
    name             => $params->{name},
    description      => $params->{description},
    default_bug_type => $params->{default_bug_type},
    defaultmilestone => $params->{default_milestone},

    # Accept the old param name `version` for backward compatibility
    default_version => $params->{default_version} || $params->{version},

    # create_series has no default value.
    create_series => defined $params->{create_series}
    ? $params->{create_series}
    : 1
  };
  foreach my $field (qw(has_unconfirmed is_open classification)) {
    if (defined $params->{$field}) {
      my $name = FIELD_MAP->{$field} || $field;
      $args->{$name} = $params->{$field};
    }
  }
  my $product = Bugzilla::Product->create($args);
  return $self->render(json => {id => 0 + $product->id}, status => 201);
}

sub _product_to_hash {
  my ($self, $params, $product) = @_;

  my $field_data = {
    id                => 0 + $product->id,
    name              => $product->name,
    description       => $product->description,
    is_active         => $product->is_active ? true : false,
    default_milestone => $product->default_milestone,
    default_version   => $product->default_version,
    has_unconfirmed   => $product->allows_unconfirmed ? true : false,
    classification    => $product->classification->name,
    default_bug_type  => $product->default_bug_type,
  };
  if (filter_wants($params, 'components')) {
    $field_data->{components}
      = [map { $self->_component_to_hash($_, $params) } @{$product->components}];
  }
  if (filter_wants($params, 'versions')) {
    $field_data->{versions}
      = [map { $self->_version_to_hash($_, $params) } @{$product->versions}];
  }
  if (filter_wants($params, 'milestones')) {
    $field_data->{milestones}
      = [map { $self->_milestone_to_hash($_, $params) } @{$product->milestones}];
  }

  # BMO - add default hw/os
  $field_data->{default_platform} = $product->default_platform;
  $field_data->{default_op_sys}   = $product->default_op_sys;

  # BMO - add default security group
  $field_data->{default_security_group} = $product->default_security_group;
  return filter($params, $field_data);
}

sub _component_to_hash {
  my ($self, $component, $params) = @_;
  my $field_data = filter $params, {
    id                  => 0 + $component->id,
    name                => $component->name,
    description         => $component->description,
    default_assigned_to => _email($component->default_assignee->login),
    default_qa_contact  => _email($component->default_qa_contact->login),
    triage_owner        => _email($component->triage_owner->login),
    sort_key =>    # sort_key is returned to match Bug.fields
      0,
    is_active        => $component->is_active ? true : false,
    default_bug_type => $component->default_bug_type,
    team_name        => $component->team_name,
    },
    undef, 'components';

  if (filter_wants($params, 'flag_types', undef, 'components')) {
    $field_data->{flag_types} = {
      bug => [
        map { $FLAG_CACHE{$_->id} //= $self->_flag_type_to_hash($_) }
          @{$component->flag_types->{'bug'}}
      ],
      attachment => [
        map { $FLAG_CACHE{$_->id} //= $self->_flag_type_to_hash($_) }
          @{$component->flag_types->{'attachment'}}
      ],
    };
  }

  return $field_data;
}

sub _flag_type_to_hash {
  my ($self, $flag_type) = @_;
  return {
    id               => 0 + $flag_type->id,
    name             => $flag_type->name,
    description      => $flag_type->description,
    cc_list          => $flag_type->cc_list,
    sort_key         => 0 + $flag_type->sortkey,
    is_active        => $flag_type->is_active        ? true : false,
    is_requestable   => $flag_type->is_requestable   ? true : false,
    is_requesteeble  => $flag_type->is_requesteeble  ? true : false,
    is_multiplicable => $flag_type->is_multiplicable ? true : false,
    grant_group      => _int_or_null($flag_type->grant_group_id),
    request_group    => _int_or_null($flag_type->request_group_id),
  };
}

sub _version_to_hash {
  my ($self, $version, $params) = @_;
  return filter $params, {
    id   => 0 + $version->id,
    name => $version->name,
    sort_key =>    # sort_key is returned to match Bug.fields
      0,
    is_active => $version->is_active ? true : false,
    },
    undef, 'versions';
}

sub _milestone_to_hash {
  my ($self, $milestone, $params) = @_;
  return filter $params,
    {
    id        => 0 + $milestone->id,
    name      => $milestone->name,
    sort_key  => 0 + $milestone->sortkey,
    is_active => $milestone->is_active ? true : false,
    },
    undef, 'milestones';
}

# Legacy type('email') only filtered when the webservice_email_filter
# parameter is on.
sub _email {
  my ($login) = @_;
  return Bugzilla->params->{webservice_email_filter} ? email_filter($login) : $login;
}

# Legacy type('int') rendered undef as JSON null rather than 0.
sub _int_or_null {
  my ($value) = @_;
  return defined $value ? 0 + $value : undef;
}

1;
