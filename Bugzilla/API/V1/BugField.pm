# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::BugField;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use List::MoreUtils qw(uniq);
use Mojo::JSON      qw(true false);

use Bugzilla::Bug;
use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::Field;
use Bugzilla::FlagType;
use Bugzilla::Keyword;
use Bugzilla::Milestone;
use Bugzilla::Product;
use Bugzilla::Status;
use Bugzilla::Version;
use Bugzilla::WebService::Util qw(filter);

use constant PRODUCT_SPECIFIC_FIELDS => qw(version target_milestone component);

sub setup_routes {
  my ($class, $r) = @_;
  my $routes
    = $r->under('/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  my @routes = (
    ['/field/bug'                           => 'fields'],
    ['/field/bug/#id_or_name'               => 'fields'],
    ['/field/bug/#field/values'             => 'legal_values'],
    ['/field/bug/#field/#product_id/values' => 'legal_values'],
    ['/flag_types/#product'                 => 'flag_types'],
    ['/flag_types/#product/#component'      => 'flag_types'],
  );
  foreach my $route (@routes) {
    my ($path, $action) = @$route;
    $routes->get($path)->to("V1::BugField#$action");
    $routes->options($path)->to('V1::BugField#options');
  }
}

sub options {
  my ($self) = @_;

  $self->res->headers->header('Allow'                        => 'GET');
  $self->res->headers->header('Access-Control-Allow-Methods' => 'GET');

  return $self->rendered(200);
}

# GET /field/bug and /field/bug/<id_or_name>
sub fields {
  my ($self) = @_;

  $self->bugzilla->login;

  my $params = {};
  for my $name (qw(ids names include_fields exclude_fields)) {
    my $values = $self->every_param($name);
    $params->{$name} = $values if @$values;
  }

  for my $name (qw(include_fields exclude_fields)) {
    $params->{$name} = [map { split(/[\s,]+/) } @{$params->{$name}}]
      if exists $params->{$name};
  }

  # As on the legacy REST server, an id or name in the path is added to the
  # ones from the query string.
  if (defined(my $id_or_name = $self->stash('id_or_name'))) {
    my $key = $id_or_name =~ /^\d+$/ ? 'ids' : 'names';
    $params->{$key} = [uniq($id_or_name, @{$params->{$key} || []})];
  }

  Bugzilla->switch_to_shadow_db();

  my @fields;
  if (defined $params->{ids}) {
    foreach my $id (@{$params->{ids}}) {
      push(@fields, Bugzilla::Field->check({id => $id}));
    }
  }

  if (defined $params->{names}) {
    foreach my $field_name (@{$params->{names}}) {
      my $loop_field = Bugzilla::Field->check($field_name);

      # Don't push in duplicate fields if we also asked for this field
      # in "ids".
      if (!grep($_->id == $loop_field->id, @fields)) {
        push(@fields, $loop_field);
      }
    }
  }

  if (!defined $params->{ids} and !defined $params->{names}) {
    @fields = @{Bugzilla->fields({obsolete => 0})};
  }

  my @fields_out;
  foreach my $field (@fields) {
    my $visibility_field
      = $field->visibility_field ? $field->visibility_field->name : undef;
    my $vis_values  = $field->visibility_values;
    my $value_field = $field->value_field ? $field->value_field->name : undef;

    my (@values, $has_values);
    if ( ($field->is_select and $field->name ne 'product')
      or grep($_ eq $field->name, PRODUCT_SPECIFIC_FIELDS)
      or $field->name eq 'keywords')
    {
      $has_values = 1;
      @values     = @{_legal_field_values($field)};
    }

    if (grep($_ eq $field->name, PRODUCT_SPECIFIC_FIELDS)) {
      $value_field = 'product';
    }

    my %field_data = (
      id                => 0 + $field->id,
      type              => 0 + $field->type,
      is_custom         => $field->custom ? true : false,
      name              => $field->name,
      display_name      => $field->description,
      is_mandatory      => $field->is_mandatory ? true : false,
      is_on_bug_entry   => $field->enter_bug    ? true : false,
      visibility_field  => $visibility_field,
      visibility_values => [map { $_->name } @$vis_values],
    );
    if ($has_values) {
      $field_data{value_field} = $value_field;
      $field_data{values}      = \@values;
    }
    push(@fields_out, filter $params, \%field_data);
  }

  return $self->render(json => {fields => \@fields_out});
}

sub _legal_field_values {
  my ($field)    = @_;
  my $field_name = $field->name;
  my $user       = Bugzilla->user;

  my @result;
  if (grep($_ eq $field_name, PRODUCT_SPECIFIC_FIELDS)) {
    my @list;
    if ($field_name eq 'version') {
      @list = Bugzilla::Version->get_all;
    }
    elsif ($field_name eq 'component') {
      @list = Bugzilla::Component->get_all;
    }
    else {
      @list = Bugzilla::Milestone->get_all;
    }

    foreach my $value (@list) {
      my $sortkey = $field_name eq 'target_milestone' ? 0 + $value->sortkey : 0;

      # XXX This is very slow for large numbers of values.
      my $product_name = $value->product->name;
      if ($user->can_see_product($product_name)) {
        push(
          @result,
          {
            name              => $value->name,
            sort_key          => $sortkey,
            sortkey           => $sortkey,          # deprecated
            visibility_values => [$product_name],
          }
        );
      }
    }
  }

  elsif ($field_name eq 'bug_status') {
    my @status_all = Bugzilla::Status->get_all;
    foreach my $status (@status_all) {
      my @can_change_to;
      foreach my $change_to (@{$status->can_change_to}) {

        # There's no need to note that a status can transition
        # to itself.
        next if $change_to->id == $status->id;
        push(
          @can_change_to,
          {
            name             => $change_to->name,
            comment_required => $change_to->comment_required_on_change_from($status)
            ? true
            : false,
          }
        );
      }

      push(
        @result,
        {
          name              => $status->name,
          is_open           => $status->is_open ? true : false,
          sort_key          => 0 + $status->sortkey,
          sortkey           => 0 + $status->sortkey,              # deprecated
          can_change_to     => \@can_change_to,
          visibility_values => [],
        }
      );
    }
  }

  elsif ($field_name eq 'keywords') {
    my @legal_keywords = Bugzilla::Keyword->get_all;
    foreach my $value (@legal_keywords) {
      next unless $value->is_active;
      push(@result, {name => $value->name, description => $value->description});
    }
  }
  else {
    my @values = Bugzilla::Field::Choice->type($field)->get_all();
    foreach my $value (@values) {
      my $vis_val = $value->visibility_value;
      push(
        @result,
        {
          name              => $value->name,
          sort_key          => 0 + $value->sortkey,
          sortkey           => 0 + $value->sortkey,                        # deprecated
          visibility_values => [defined $vis_val ? $vis_val->name : ()],
        }
      );
    }
  }

  return \@result;
}

# GET /field/bug/<field>/values and /field/bug/<field>/<product_id>/values
sub legal_values {
  my ($self) = @_;

  my $user = $self->bugzilla->login;

  Bugzilla->switch_to_shadow_db();

  my $field_param = $self->stash('field');
  my $field       = Bugzilla::Bug::FIELD_MAP->{$field_param} || $field_param;

  my @global_selects = @{Bugzilla->fields({is_select => 1, is_abnormal => 0})};

  my $values;
  if (grep($_->name eq $field, @global_selects)) {

    # The field is a valid one.
    $values = get_legal_field_values($field);
  }
  elsif (grep($_ eq $field, PRODUCT_SPECIFIC_FIELDS)) {

    # The path value wins over a product_id query parameter, as on the legacy
    # REST server.
    my $id = $self->param('product_id');
    defined $id
      || return $self->code_error('param_required',
      {function => 'Bug.legal_values', param => 'product_id'});
    grep($_->id eq $id, @{$user->get_accessible_products})
      || return $self->user_error('product_access_denied', {id => $id});

    my $product = Bugzilla::Product->new($id);
    my @objects;
    if ($field eq 'version') {
      @objects = @{$product->versions};
    }
    elsif ($field eq 'target_milestone') {
      @objects = @{$product->milestones};
    }
    elsif ($field eq 'component') {
      @objects = @{$product->components};
    }

    $values = [map { $_->name } @objects];
  }
  else {
    return $self->code_error('invalid_field_name', {field => $field_param});
  }

  return $self->render(json => {values => [map {"$_"} @$values]});
}

# GET /flag_types/<product> and /flag_types/<product>/<component>
sub flag_types {
  my ($self) = @_;

  $self->bugzilla->login;

  Bugzilla->switch_to_shadow_db();

  # A component query parameter is used when the path has none, as on the
  # legacy REST server.
  my $product   = $self->stash('product');
  my $component = $self->param('component');

  $product = Bugzilla::Product->check({name => $product, cache => 1});
  $component
    = Bugzilla::Component->check(
    {name => $component, product => $product, cache => 1})
    if $component;

  my $flag_params = {product_id => $product->id};
  $flag_params->{component_id} = $component->id if $component;
  my $matched_flag_types = Bugzilla::FlagType::match($flag_params);

  my $flag_types = {bug => [], attachment => []};
  foreach my $flag_type (@$matched_flag_types) {
    push(
      @{$flag_types->{$flag_type->target_type}},
      _flagtype_to_hash($flag_type, $product)
    ) if exists $flag_types->{$flag_type->target_type};
  }

  return $self->render(json => $flag_types);
}

sub _flagtype_to_hash {
  my ($flagtype, $product) = @_;
  my $user = Bugzilla->user;

  my @values = ('X');
  push(@values, '?')
    if ($flagtype->is_requestable && $user->can_request_flag($flagtype));
  push(@values, '+', '-') if $user->can_set_flag($flagtype);

  my $item = {
    id               => 0 + $flagtype->id,
    name             => $flagtype->name,
    description      => $flagtype->description,
    type             => $flagtype->target_type,
    values           => \@values,
    is_active        => $flagtype->is_active        ? true : false,
    is_requesteeble  => $flagtype->is_requesteeble  ? true : false,
    is_multiplicable => $flagtype->is_multiplicable ? true : false,
  };

  my $inclusions
    = _flagtype_clusions_to_hash($flagtype->inclusions, $product->id);
  my $exclusions
    = _flagtype_clusions_to_hash($flagtype->exclusions, $product->id);

  # if we have both inclusions and exclusions, the exclusions are redundant
  $exclusions = [] if @$inclusions && @$exclusions;

  # no need to return anything if there's just "any component"
  $item->{inclusions} = $inclusions if @$inclusions && $inclusions->[0] ne '';
  $item->{exclusions} = $exclusions if @$exclusions && $exclusions->[0] ne '';

  return $item;
}

sub _flagtype_clusions_to_hash {
  my ($clusions, $product_id) = @_;
  my $result = [];
  foreach my $key (keys %$clusions) {
    my ($prod_id, $comp_id) = split(/:/, $clusions->{$key}, 2);
    if ($prod_id == 0 || $prod_id == $product_id) {
      if ($comp_id) {
        my $component = Bugzilla::Component->new({id => $comp_id, cache => 1});
        push @$result, $component->name;
      }
      else {
        return [''];
      }
    }
  }
  return $result;
}

1;
