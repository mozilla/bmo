# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::BugModal::API::V1::BugModal;

use 5.10.1;
use Mojo::Base qw(Mojolicious::Controller);

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Comment;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Field;
use Bugzilla::Group;
use Bugzilla::Keyword;
use Bugzilla::Logging;
use Bugzilla::Milestone;
use Bugzilla::Product;
use Bugzilla::Util qw(detaint_natural);
use Bugzilla::Version;
use Bugzilla::API::V1::Util qw(merge_request_params);
use List::MoreUtils         qw(any first_value);

# these methods are much lighter than our public API calls

sub setup_routes {
  my ($class, $r) = @_;
  my $to = 'BugModal::API::V1::BugModal#';
  my @id = (id => qr/\d+/);

  # return all the products accessible by the user.
  # required by new-bug
  $r->get('/bug_modal/initial_field_values')->to($to . 'initial_field_values');

  # return all the components pertaining to the product (?product=).
  # required by new-bug
  $r->get('/bug_modal/product_info')->to($to . 'product_info');

  # return all the lazy-loaded data; kept in sync with the UI's
  # requirements.
  $r->get('/bug_modal/edit/:id' => [@id])->to($to . 'edit');

  # returns pre-formatted HTML, enabling reuse of the user template
  $r->get('/bug_modal/cc/:id' => [@id])->to($to . 'cc');

  # returns pre-formatted HTML representing the comment tags
  $r->get('/bug_modal/comment_tags/:id' => [@id])->to($to . 'comment_tags');

  # make changes to comment tags and return preformatted html
  $r->put('/bug_modal/update_comment_tags/:id' => [@id])
    ->to($to . 'update_comment_tags');

  # returns fields that require touching when the product is changed.
  # products with slashes in their name means we have to grab the product
  # from the query-string (?product=) instead of the path
  $r->get('/bug_modal/new_product/:id' => [@id])->to($to . 'new_product');
}

sub type {
  my ($self, $type, $value) = @_;
  return Bugzilla::API::V1::Util->type($type, $value);
}

# The request params with the id from the path. As on the legacy server, an
# id sent with a PUT replaces the one in the path, but not on a GET. Logs the
# user in if credentials were sent. Returns nothing after rendering an error.
sub _params {
  my ($self, $lists) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  $self->bugzilla->login;

  my ($params, $error) = merge_request_params($self, $lists);
  if ($error) {
    $self->user_error($error);
    return;
  }
  $params->{id} = $self->stash('id')
    if $self->req->method eq 'GET' || !defined $params->{id};
  return $params;
}

# GET /bug_modal/initial_field_values
sub initial_field_values {
  my ($self) = @_;
  $self->_params or return;
  my $user = Bugzilla->user;
  return $self->render(
    json => {
      products          => _name($user->get_enterable_products),
      keywords          => _name([Bugzilla::Keyword->get_all()]),
      default_bug_types => get_legal_field_values('bug_type'),
    }
  );
}

# GET /bug_modal/product_info?product=<name>
sub product_info {
  my ($self) = @_;
  my $params = $self->_params or return;
  ThrowCodeError('params_required',
    {function => 'BugModal.components', params => ['product']})
    if ref $params->{product};
  my $product
    = Bugzilla::Product->check({name => $params->{product}, cache => 1});
  $product = Bugzilla->user->can_enter_product($product, 1);
  my @components = map { {
    name             => $_->name,
    description      => $_->description,
    default_bug_type => $_->default_bug_type,
  } } @{$product->components};
  return $self->render(
    json => {components => \@components, versions => _name($product->versions)});
}

# everything we need for edit mode in a single call, returning just the fields
# that the ui requires.
#
# GET /bug_modal/edit/<id>
sub edit {
  my ($self) = @_;
  my $params = $self->_params or return;
  my $user   = Bugzilla->user;
  my $bug    = Bugzilla::Bug->check({id => $params->{id}});

  # the keys of the options hash must match the field id in the ui
  my %options;

  my @products = @{$user->get_enterable_products};
  unless (grep { $_->id == $bug->product_id } @products) {
    unshift @products, $bug->product_obj;
  }
  $options{product} = [map { {name => $_->name} } @products];

  $options{component} = _name($bug->product_obj->components, $bug->component);
  $options{version}   = _name($bug->product_obj->versions,   $bug->version);
  $options{target_milestone}
    = _name($bug->product_obj->milestones, $bug->target_milestone);
  $options{priority}     = _name('priority',     $bug->priority);
  $options{bug_severity} = _name('bug_severity', $bug->bug_severity);
  $options{rep_platform} = _name('rep_platform', $bug->rep_platform);
  $options{op_sys}       = _name('op_sys',       $bug->op_sys);
  $options{bug_type}     = _name('bug_type',     $bug->bug_type);

  # custom select fields
  my @custom_fields = grep {
    $_->type == FIELD_TYPE_SINGLE_SELECT || $_->type == FIELD_TYPE_MULTI_SELECT
  } Bugzilla->active_custom_fields(
    {product => $bug->product_obj, component => $bug->component_obj});
  foreach my $field (@custom_fields) {
    my $field_name = $field->name;
    my @values;
    foreach my $value (@{$field->legal_values}) {
      my $can_change
        = $bug->check_can_change_field($field_name, $bug->$field_name, $value->name);
      if ($bug->$field_name eq $value->name
        || ($value->is_active && $can_change->{allowed}))
      {
        push @values, {name => $value->name};
      }
    }
    $options{$field_name} = \@values;
  }

  # keywords
  my @keywords = grep { $_->is_active } Bugzilla::Keyword->get_all();

  # results
  return $self->render(
    json => {options => \%options, keywords => [map { $_->name } @keywords]});
}

sub _name {
  my ($values, $current) = @_;

  # values can either be an array-ref of values, or a field name, which
  # result in that field's legal-values being used.
  if (!ref($values)) {
    $values = Bugzilla::Field->new({name => $values, cache => 1})->legal_values;
  }
  return [map { {name => $_->name} }
    grep { (defined $current && $_->name eq $current) || $_->is_active } @$values];
}

# GET /bug_modal/cc/<id>
sub cc {
  my ($self)   = @_;
  my $params   = $self->_params or return;
  my $template = Bugzilla->template;
  my $bug      = Bugzilla::Bug->check({id => $params->{id}});
  my $vars     = {
    bug     => $bug,
    cc_list => [sort { lc($a->identity) cmp lc($b->identity) } @{$bug->cc_users}]
  };

  my $html = '';
  $template->process('bug_modal/cc_list.html.tmpl', $vars, \$html)
    || ThrowTemplateError($template->error);
  return $self->render(json => {html => $html});
}

# GET /bug_modal/comment_tags/<comment id>
sub comment_tags {
  my ($self)   = @_;
  my $params   = $self->_params or return;
  my $user     = Bugzilla->user;
  my $template = Bugzilla->template;

  my $id = $params->{id};
  detaint_natural($id)
    || ThrowCodeError('param_must_be_numeric',
    {function => 'BugModal.comment_tags', param => 'id'});
  my $comment = Bugzilla::Comment->new($id);
  ThrowUserError('comment_id_invalid', {id => $id}) if !$comment;

  # Now make sure that we can see the associated bug.
  $comment->bug->check_is_visible();

  # Make sure user can see comment
  if ($comment->is_private && !$user->is_insider) {
    ThrowUserError('comment_is_private', {id => $comment->id});
  }

  return $self->render(json => {html => _render_comment_html($comment, $user)});
}

# PUT /bug_modal/update_comment_tags/<comment id> {add: [...], remove: [...]}
sub update_comment_tags {
  my ($self) = @_;
  my $params = $self->_params([qw(add remove)]) or return;
  my $user   = Bugzilla->user;
  $user->id || ThrowUserError('login_required');

  Bugzilla->params->{'comment_taggers_group'}
    || ThrowUserError('comment_tag_disabled');
  $user->can_tag_comments || ThrowUserError(
    'auth_failure',
    {
      group  => Bugzilla->params->{'comment_taggers_group'},
      action => 'update',
      object => 'comment_tags'
    }
  );

  my $id = $params->{id};
  detaint_natural($id)
    || ThrowCodeError('param_must_be_numeric',
    {function => 'BugModal.update_comment_tags', param => 'id'});
  my $comment = Bugzilla::Comment->new($id);
  ThrowUserError('comment_id_invalid', {id => $id}) if !$comment;

  # Now make sure that we can see the associated bug.
  $comment->bug->check_is_visible();

  # Make sure user can see comment
  if ($comment->is_private && !$user->is_insider) {
    ThrowUserError('comment_is_private', {id => $id});
  }

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction();
  foreach my $tag (@{$params->{add} || []}) {
    $comment->add_tag($tag) if defined $tag;
  }
  foreach my $tag (@{$params->{remove} || []}) {
    $comment->remove_tag($tag) if defined $tag;
  }
  $comment->update();
  $dbh->bz_commit_transaction();

  return $self->render(json => {html => _render_comment_html($comment, $user)});
}

sub _render_comment_html {
  my ($comment, $user) = @_;
  my $template = Bugzilla->template;
  my $html     = '';
  my $vars     = {
    comment  => $comment,
    user     => $user,
    basepath => Bugzilla->localconfig->basepath
  };
  $template->process('bug_modal/comment_tags.html.tmpl', $vars, \$html)
    || ThrowTemplateError($template->error);
  return $html;
}

# GET /bug_modal/new_product/<id>?product=<name>
sub new_product {
  my ($self) = @_;
  my $params = $self->_params or return;
  my $dbh    = Bugzilla->dbh;
  my $user   = Bugzilla->user;
  my $bug    = Bugzilla::Bug->check({id => $params->{id}});
  ThrowCodeError('params_required',
    {function => 'BugModal.new_product', params => ['product']})
    if ref $params->{product};
  my $product
    = Bugzilla::Product->check({name => $params->{product}, cache => 1});
  my $true = $self->type('boolean', 1);
  my %result;

  # components

  my $components        = _name($product->components);
  my $current_component = $bug->component;
  if (my $component
    = first_value { $_->{name} eq $current_component } @$components)
  {
    # identical component in both products
    $component->{selected} = $true;
  }
  elsif (scalar @{$components} == 1) {

    # New product has one component so preselect it
    $components->[0]->{selected} = $true;
  }
  else {
    # default to a blank value
    unshift @$components, {name => '', selected => $true,};
  }
  $result{component} = $components;

  # milestones

  my $milestones        = _name($product->milestones);
  my $current_milestone = $bug->target_milestone;
  my $can_change        = $bug->check_can_change_field('target_milestone', 0, 1);
  if (
    $can_change->{allowed}
    && (my $milestone
      = first_value { $_->{name} eq $current_milestone } @$milestones)
    )
  {
    # identical milestone in both products
    $milestone->{selected} = $true;
  }
  else {
    # use default milestone
    my $default_milestone = $product->default_milestone;
    my $milestone = first_value { $_->{name} eq $default_milestone } @$milestones;
    $milestone->{selected} = $true;
  }
  $result{target_milestone} = $milestones;

  # versions

  my $versions        = _name($product->versions);
  my $current_version = $bug->version;
  my $selected_version;
  if (my $version = first_value { $_->{name} eq $current_version } @$versions) {

    # identical version in both products
    $version->{selected} = $true;
    $selected_version = $version;
  }
  elsif ($current_version =~ /^(\d+) Branch$/
    || $current_version =~ /^Firefox (\d+)$/
    || $current_version =~ /^(\d+)$/)
  {
    # Firefox, with its three version naming schemes
    my $branch = $1;
    foreach my $test_version ("$branch Branch", "Firefox $branch", $branch) {
      if (my $version = first_value { $_->{name} eq $test_version } @$versions) {
        $version->{selected} = $true;
        $selected_version = $version;
        last;
      }
    }
  }
  if (!$selected_version) {

    # "unspecified", "other"
    foreach my $test_version ("unspecified", "other") {
      if (my $version = first_value { lc($_->{name}) eq $test_version } @$versions) {
        $version->{selected} = $true;
        $selected_version = $version;
        last;
      }
    }
  }
  if (!$selected_version) {

    # use default version
    my $default_version = $product->default_version;
    my $version         = first_value { $_->{name} eq $default_version } @$versions;
    $version->{selected} = $true;
  }
  $result{version} = $versions;

  # groups

  my @groups;

  # find invalid groups
  push @groups,
    map { {type => 'invalid', group => $_, checked => 0, locked => 0,} }
    @{Bugzilla::Bug->get_invalid_groups(
      {bug_ids => [$bug->id], product => $product})};

  # logic lifted from bug/process/verify-new-product.html.tmpl
  my $current_groups = $bug->groups_in;
  my $group_controls = $product->group_controls;
  foreach my $group_id (keys %$group_controls) {
    my $group_control = $group_controls->{$group_id};
    if (
      $group_control->{membercontrol} == CONTROLMAPMANDATORY
      || ($group_control->{othercontrol} == CONTROLMAPMANDATORY
        && !$user->in_group($group_control->{name}))
      )
    {
      # mandatory, always checked
      push @groups,
        {
        type    => 'mandatory',
        group   => $group_control->{group},
        checked => 1,
        locked  => 0,
        };
    }
    elsif (
      (
           $group_control->{membercontrol} != CONTROLMAPNA
        && $user->in_group($group_control->{name})
      )
      || $group_control->{othercontrol} != CONTROLMAPNA
      )
    {
      # optional, checked if..
      my $group    = $group_control->{group};
      my $in_group = any { $_->id == $group->id } @$current_groups;
      my $checked =

        # same group as current product
        $in_group

        # member default
        || $group_control->{membercontrol} == CONTROLMAPDEFAULT
        && $user->in_group($group_control->{name})

        # or other default
        || $group_control->{othercontrol} == CONTROLMAPDEFAULT
        && !$user->in_group($group_control->{name});

      # Only members of a group may lift a restriction that is already in
      # place, so for everyone else the checkbox is locked and the group is
      # left out of defined_groups (bug 2062223). Without this the user is
      # offered a removal that remove_group() then rejects.
      my $locked = $in_group && !$user->in_group($group_control->{name});
      push @groups,
        {
        type    => 'optional',
        group   => $group_control->{group},
        checked => $checked || 0,
        locked  => $locked  || 0,
        };
    }
  }

  my $default_group_name = $product->default_security_group;
  if (my $default_group
    = first_value { $_->{group}->name eq $default_group_name } @groups)
  {
# because we always allow the default product group to be selected, it's never invalid
    $default_group->{type} = 'optional' if $default_group->{type} eq 'invalid';
  }
  else {
    # add the product's default group if it's missing
    unshift @groups,
      {
      type    => 'optional',
      group   => $product->default_security_group_obj,
      checked => 0,
      locked  => 0,
      };
  }

  # if the bug is currently in a group, ensure a group is checked by default
  # by checking the product's default group if no other groups apply
  if (@$current_groups && !any { $_->{checked} } @groups) {
    foreach my $g (@groups) {
      next unless $g->{group}->name eq $default_group_name;
      $g->{checked} = 1;
      last;
    }
  }

  # group by type and flatten
  my $vars = {
    product => $product,
    groups  => {invalid => [], mandatory => [], optional => []},
  };
  foreach my $g (@groups) {
    push @{$vars->{groups}->{$g->{type}}},
      {
      id          => $g->{group}->id,
      name        => $g->{group}->name,
      description => $g->{group}->description,
      checked     => $g->{checked},
      locked      => $g->{locked},
      };
  }

  # build group selection HTML
  my $template = Bugzilla->template;
  $template->process('bug_modal/new_product_groups.html.tmpl',
    $vars, \$result{groups})
    || ThrowTemplateError($template->error);

  return $self->render(json => \%result);
}

1;
