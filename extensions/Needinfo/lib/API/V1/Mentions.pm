# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Needinfo::API::V1::Mentions;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Bug;
use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::API::V1::Util qw(coerce_booleans merge_request_params);

sub setup_routes {
  my ($class, $r) = @_;
  $r->post('/needinfo/mentions')->to('Needinfo::API::V1::Mentions#mentions');
}

# POST /needinfo/mentions
#
# Lists the users that the @mentions in a new comment would CC and needinfo,
# without rendering the comment. The comment editor calls this as the user
# types, to warn before saving. Params:
#   text        the comment text (required)
#   id          id or alias of the bug the comment is added to, or
#   product     name of the product a new bug is being filed in, with optional
#   component   component name and
#   groups      bug group names for the new bug
#   is_private  whether the comment is private
# Returns {mentions => [{nick, name, needinfo}]}; see
# Bugzilla::Extension::Needinfo::mention_effects.
sub mentions {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $error) = merge_request_params($self, ['groups']);
  return $self->user_error($error) if $error;

  if ($error = coerce_booleans($params, 'is_private')) {
    return $self->user_error('invalid_params', {type_error => $error});
  }

  if (!defined $params->{text}) {
    return $self->code_error('params_required',
      {function => 'Needinfo.mentions', params => ['text']});
  }
  if (!$params->{id} && !$params->{product}) {
    return $self->code_error('params_required',
      {function => 'Needinfo.mentions', params => ['id', 'product']});
  }

  # Single values, so they can't reach the object loaders as conditions.
  foreach my $name (qw(text id product component)) {
    next unless ref $params->{$name};
    return $self->user_error('invalid_params',
      {type_error => "$name must be a single value"});
  }
  my $groups = $params->{groups} // [];
  $groups = [$groups] unless ref $groups;
  if (ref $groups ne 'ARRAY' || grep {ref} @$groups) {
    return $self->user_error('invalid_params',
      {type_error => 'groups must be a list of group names'});
  }

  my $comment = {thetext => $params->{text}, isprivate => $params->{is_private}};

  # Nothing to look up without an @, the common case while typing.
  return $self->render(json => {mentions => []}) unless $params->{text} =~ /@/;

  Bugzilla->switch_to_shadow_db();

  my $target;
  if ($params->{id}) {
    $target = {bug => Bugzilla::Bug->check($params->{id})};
  }
  else {
    my $product = $user->can_enter_product($params->{product}, THROW_ERROR);
    my $component
      = defined $params->{component} && $params->{component} ne ''
      ? Bugzilla::Component->new({product => $product, name => $params->{component}
      })
      : undef;
    $target = {product => $product, component => $component, groups => $groups,};
  }

  return $self->render(
    json => {
      mentions => Bugzilla::Extension::Needinfo::mention_effects($comment, $target)
    }
  );
}

1;
