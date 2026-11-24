# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::ComponentWatching::API::V1::ComponentWatching;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Product;
use Bugzilla::API::V1::Util qw(merge_request_params render_options);

sub setup_routes {
  my ($class, $r) = @_;
  my $to = 'ComponentWatching::API::V1::ComponentWatching#';
  $r->get('/component-watching')->to($to . 'list');
  $r->post('/component-watching')->to($to . 'add');
  $r->get('/component-watching/:id' => [id => qr/\d+/])->to($to . 'get');
  $r->delete('/component-watching/:id' => [id => qr/\d+/])->to($to . 'remove');
  $r->options('/component-watching')
    ->to(cb => \&render_options, allow => 'GET, POST');
  $r->options('/component-watching/:id' => [id => qr/\d+/])
    ->to(cb => \&render_options, allow => 'DELETE, GET');
}

#
# API methods based on Bugzilla::Extension::ComponentWatching->user_preferences
#

# The logged-in user, or undef after rendering a login_required error.
sub _login {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;
  return $user if $user->id;
  $self->user_error('login_required');
  return undef;
}

# GET /component-watching
#
# Returns the user's watches, sorted by product, component and prefix.
sub list {
  my ($self) = @_;
  my $user = $self->_login || return;

  return $self->render(
    json => Bugzilla::Extension::ComponentWatching::_getWatches($user));
}

# POST /component-watching
#
# Watches a product (no component, or an empty one) or components of it.
# Params: product, component (a name or a list of names). Returns the new
# watch, or null when it was already watched.
sub add {
  my ($self) = @_;
  my $user = $self->_login || return;

  my ($params, $error, $vars) = merge_request_params($self, ['component']);
  return $self->user_error($error, $vars) if $error;
  my $result;

  # load product and verify access
  my $productName = $params->{'product'};
  my $product     = Bugzilla::Product->new({name => $productName, cache => 1});
  unless ($product && $user->can_access_product($product)) {
    ThrowUserError('product_access_denied', {name => $productName});
  }

  my $ra_componentNames = $params->{'component'};
  $ra_componentNames = [$ra_componentNames || ''] unless ref($ra_componentNames);

  if (grep { $_ eq '' } @$ra_componentNames) {

    # watching a product
    $result
      = Bugzilla::Extension::ComponentWatching::_addProductWatch($user, $product);

  }
  else {
    # watching specific components
    foreach my $componentName (@$ra_componentNames) {
      my $component
        = Bugzilla::Component->new({
        name => $componentName, product => $product, cache => 1
        });
      unless ($component) {
        ThrowUserError('product_access_denied', {name => $productName});
      }
      $result = Bugzilla::Extension::ComponentWatching::_addComponentWatch($user,
        $component);
    }
  }

  Bugzilla::Extension::ComponentWatching::_addDefaultSettings($user);

  return $self->render(json => $result);
}

# GET /component-watching/<id>
#
# Returns the user's watch with this id, or {} if there is none.
sub get {
  my ($self) = @_;
  my $user = $self->_login || return;

  return $self->render(
    json => Bugzilla::Extension::ComponentWatching::_getWatches(
      $user, $self->param('id')
    )
  );
}

# DELETE /component-watching/<id>
#
# Removes the user's watch with this id. Returns {status => <rows deleted>}.
sub remove {
  my ($self) = @_;
  my $user = $self->_login || return;

  return $self->render(
    json => {
      status => Bugzilla::Extension::ComponentWatching::_deleteWatch(
        $user, $self->param('id')
      )
    }
  );
}

1;
