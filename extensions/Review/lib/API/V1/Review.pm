# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Review::API::V1::Review;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::FlagActivity;
use Bugzilla::FlagType;
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::Util          qw(detaint_natural );
use Bugzilla::API::V1::Util qw(filter merge_request_params);

use DateTime;

sub setup_routes {
  my ($class, $r) = @_;
  my $to = 'Review::API::V1::Review#';

  # bug-id
  $r->get('/review/suggestions/:bug_id' => [bug_id => qr/\d+/])
    ->to($to . 'suggestions');

  # product/component (the component name may contain slashes)
  $r->get('/review/suggestions/#product/*component')->to($to . 'suggestions');

  # just product
  $r->get('/review/suggestions/#product')->to($to . 'suggestions');

  # named parameters
  $r->get('/review/suggestions')->to($to . 'suggestions');

  # flag activity by flag id
  $r->get('/review/flag_activity/:flag_id' => [flag_id => qr/\d+/])
    ->to($to . 'flag_activity');
  $r->get('/review/flag_activity/type_name/:type_name' => [type_name => qr/\w+/])
    ->to($to . 'flag_activity');

  # flag activity by user or type id
  $r->get('/review/flag_activity/:field/*value' =>
      [field => [qw(requestee setter type_id)]])->to($to . 'flag_activity');

  # flag activity with only query strings
  $r->get('/review/flag_activity')->to($to . 'flag_activity');
}

sub type {
  my ($self, $type, $value) = @_;
  return Bugzilla::API::V1::Util->type($type, $value);
}

# The request params with the values from the path on top, or nothing after
# rendering an error. Logs the user in if credentials were sent.
sub _params {
  my ($self, $lists, @path) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  $self->bugzilla->login;

  my ($params, $error) = merge_request_params($self, $lists);
  if ($error) {
    $self->user_error($error);
    return;
  }
  Bugzilla::API::V1::Util->split_include_exclude($params);
  foreach my $name (@path) {
    my $value = $self->stash($name);
    $params->{$name} = $value if defined $value;
  }
  return $params;
}

# GET /review/suggestions/<bug_id>
# GET /review/suggestions/<product>[/<component>]
# GET /review/suggestions?bug_id=<id> or ?product=<name>[&component=<name>]
#
# Suggested reviewers: the bug's mentors, then the component's reviewers, or
# the product's when the component has none. Returns a list of {id, email,
# name, nick, review_count}.
sub suggestions {
  my ($self) = @_;
  my $params = $self->_params([], qw(bug_id product component)) || return;
  my $dbh    = Bugzilla->switch_to_shadow_db();

  my ($bug, $product, $component);
  if (exists $params->{bug_id}) {
    $bug       = Bugzilla::Bug->check($params->{bug_id});
    $product   = $bug->product_obj;
    $component = $bug->component_obj;
  }
  elsif (exists $params->{product}) {
    $product = Bugzilla::Product->check($params->{product});
    if (exists $params->{component}) {
      $component
        = Bugzilla::Component->check({
        product => $product, name => $params->{component}
        });
    }
  }
  else {
    ThrowUserError("reviewer_suggestions_param_required");
  }

  my @reviewers;
  if ($bug) {

    # we always need to be authenticated to perform user matching
    my $user = Bugzilla->user;
    if (!$user->id) {
      Bugzilla->set_user(Bugzilla::User->check({name => 'nobody@mozilla.org'}));
      push @reviewers, @{$bug->mentors};
      Bugzilla->set_user($user);
    }
    else {
      push @reviewers, @{$bug->mentors};
    }
  }
  if ($component) {
    push @reviewers, @{$component->reviewers_objs};
  }
  if (!$component || !@{$component->reviewers_objs}) {
    push @reviewers, @{$product->reviewers_objs};
  }

  my @result;
  foreach my $reviewer (@reviewers) {
    push @result,
      {
      id           => $self->type('int',    $reviewer->id),
      email        => $self->type('email',  $reviewer->login),
      name         => $self->type('string', $reviewer->name),
      nick         => $self->type('string', $reviewer->nick),
      review_count => $self->type('int',    $reviewer->review_count),
      };
  }
  return $self->render(json => \@result);
}

# GET /review/flag_activity/<flag_id>
# GET /review/flag_activity/type_name/<name>
# GET /review/flag_activity/(requestee|setter|type_id)/<value>
# GET /review/flag_activity?<criteria>
#
# Flag activity matching flag_id(s), type_id, type_name, requestee, setter,
# bug_id and status, between after and before (default: the last 30 days),
# limit and offset. Only activity on bugs and attachments the user can see.
sub flag_activity {
  my ($self) = @_;
  my $params = $self->_params(['flag_ids'], qw(flag_id type_name)) || return;
  if (defined(my $field = $self->stash('field'))) {
    $params->{$field} = $self->stash('value');
  }
  my $dbh = Bugzilla->switch_to_shadow_db();
  my %match_criteria;

  if (my $flag_id = $params->{flag_id}) {
    detaint_natural($flag_id)
      or ThrowUserError('invalid_flag_id', {flag_id => $flag_id});

    $match_criteria{flag_id} = $flag_id;
  }

  if (my $flag_ids = $params->{flag_ids}) {
    foreach my $flag_id (@$flag_ids) {
      detaint_natural($flag_id)
        or ThrowUserError('invalid_flag_id', {flag_id => $flag_id});
    }

    $match_criteria{flag_id} = $flag_ids;
  }

  if (my $type_id = $params->{type_id}) {
    detaint_natural($type_id)
      or ThrowUserError('invalid_flag_type_id', {type_id => $type_id});

    $match_criteria{type_id} = $type_id;
  }

  if (my $type_name = $params->{type_name}) {
    my $flag_types = Bugzilla::FlagType::match({name => $type_name});
    $match_criteria{type_id} = [map { $_->id } @$flag_types];
  }

  foreach my $user_field (qw( requestee setter )) {
    if (my $user_name = $params->{$user_field}) {
      my $user = Bugzilla::User->check(
        {name => $user_name, cache => 1, _error => 'invalid_username'});

      $match_criteria{$user_field . "_id"} = $user->id;
    }
  }

  foreach my $field (qw( bug_id status )) {
    if (exists $params->{$field}) {
      $match_criteria{$field} = $params->{$field};
    }
  }

  ThrowCodeError('param_required',
    {param => 'limit', function => 'Review.flag_activity()'})
    if defined $params->{offset} && !defined $params->{limit};

  my $limit       = delete $params->{limit};
  my $offset      = delete $params->{offset};
  my $after       = delete $params->{after};
  my $before      = delete $params->{before};
  my $max_results = Bugzilla->params->{max_search_results};

  if (!$limit || $limit > $max_results) {
    $limit = $max_results;
  }

  if ($after && $after =~ /^(\d{4}-\d{1,2}-\d{1,2})$/) {
    $after = $1;
  }
  else {
    my $now = DateTime->now;
    $now->subtract(days => 30);
    $after = $now->ymd('-');
  }

  if ($before && $before =~ /^(\d{4}-\d{1,2}-\d{1,2})$/) {
    $before = $1;
  }
  else {
    my $now = DateTime->now;
    $before = $now->ymd('-');
  }

  $match_criteria{LIMIT}  = $limit;
  $match_criteria{OFFSET} = $offset if defined $offset;
  $match_criteria{WHERE}
    = {'date(flag_when) BETWEEN ? AND ?' => [$after, $before]};

 # Throw error if no other parameters have been passed other than limit and offset
  if (!grep(!/^(LIMIT|OFFSET)$/, keys %match_criteria)) {
    ThrowUserError('flag_activity_parameters_required');
  }

  my $matches = Bugzilla::FlagActivity->match(\%match_criteria);
  my $user    = Bugzilla->user;
  $user->visible_bugs([map { $_->bug_id } @$matches]);
  my @results
    = map { $self->_flag_activity_to_hash($_, $params) }
    grep  { $user->can_see_bug($_->bug_id) && _can_see_attachment($user, $_) }
    @$matches;
  return $self->render(json => \@results);
}

sub _can_see_attachment {
  my ($user, $flag_activity) = @_;

  return 1 if !$flag_activity->attachment_id;
  return 0 if $flag_activity->attachment->isprivate && !$user->is_insider;
  return 1;
}

sub _flag_activity_to_hash {
  my ($self, $fa, $params) = @_;

  my %flag = (
    id            => $self->type('int',    $fa->id),
    creation_time => $self->type('string', $fa->flag_when),
    type          => $self->_flagtype_to_hash($fa->type),
    setter        => $self->_user_to_hash($fa->setter),
    bug_id        => $self->type('int',    $fa->bug_id),
    attachment_id => $self->type('int',    $fa->attachment_id),
    status        => $self->type('string', $fa->status),
  );

  $flag{requestee} = $self->_user_to_hash($fa->requestee) if $fa->requestee;
  $flag{flag_id}   = $self->type('int', $fa->flag_id) unless $params->{flag_id};

  return filter($params, \%flag);
}

sub _flagtype_to_hash {
  my ($self, $flagtype) = @_;
  my $user = Bugzilla->user;

  return {
    id               => $self->type('int',     $flagtype->id),
    name             => $self->type('string',  $flagtype->name),
    description      => $self->type('string',  $flagtype->description),
    type             => $self->type('string',  $flagtype->target_type),
    is_active        => $self->type('boolean', $flagtype->is_active),
    is_requesteeble  => $self->type('boolean', $flagtype->is_requesteeble),
    is_multiplicable => $self->type('boolean', $flagtype->is_multiplicable),
  };
}

sub _user_to_hash {
  my ($self, $user) = @_;

  return {
    id        => $self->type('int',    $user->id),
    real_name => $self->type('string', $user->name),
    nick      => $self->type('string', $user->nick),
    name      => $self->type('email',  $user->login),
  };
}

1;
