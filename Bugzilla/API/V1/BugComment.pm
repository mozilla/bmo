# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::BugComment;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use List::MoreUtils qw(uniq);

use Bugzilla::API::V1::Util;
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::Comment;
use Bugzilla::Comment::TagWeights;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Hook;
use Bugzilla::Template;
use Bugzilla::Util qw(datetime_from detaint_natural remote_ip trim);
use Bugzilla::WebService::Util qw(merge_request_params);

sub setup_routes {
  my ($class, $r) = @_;
  my $routes
    = $r->under('/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  my @routes = (
    ['/bug/#id/comment'              => {get => 'comments', post => 'add_comment'}],
    ['/bug/comment/<comment_id:num>' => {get => 'comments'}],
    [
      '/bug/comment/#comment_id/reactions' =>
        {get => 'get_comment_reactions', put => 'update_comment_reactions'}
    ],
    ['/bug/comment/#comment_id/tags' => {put  => 'update_comment_tags'}],
    ['/bug/comment/tags/#query'      => {get  => 'search_comment_tags'}],
    ['/bug/comment/render'           => {post => 'render_comment'}],
  );
  foreach my $route (@routes) {
    my ($path, $actions) = @$route;
    foreach my $method (sort keys %$actions) {
      $routes->$method($path)->to("V1::BugComment#$actions->{$method}");
    }
    $routes->options($path)
      ->to('V1::BugComment#options',
      allow => join(', ', map {uc} sort keys %$actions));
  }
}

sub options {
  my ($self) = @_;

  my $allow = $self->stash('allow');
  $self->res->headers->header('Allow'                        => $allow);
  $self->res->headers->header('Access-Control-Allow-Methods' => $allow);

  return $self->rendered(200);
}

# Same output as type() on the legacy JSON-RPC/REST server.
sub type {
  my ($self, $type, $value) = @_;
  return Bugzilla::API::V1::Util->type($type, $value);
}

# GET /bug/<id>/comment and /bug/comment/<comment_id>
sub comments {
  my ($self) = @_;

  my $user = $self->bugzilla->login;

  my $params = {};
  for my $name (qw(ids comment_ids include_fields exclude_fields)) {
    my $values = $self->every_param($name);
    $params->{$name} = $values if @$values;
  }
  for my $name (qw(include_fields exclude_fields)) {
    $params->{$name} = [map { split(/[\s,]+/) } @{$params->{$name}}]
      if exists $params->{$name};
  }
  for my $name (qw(new_since skip_private)) {
    $params->{$name} = $self->param($name) if defined $self->param($name);
  }

  # As on the legacy REST server, an id in the path is added to the ones from
  # the query string.
  for my $pair (['id', 'ids'], ['comment_id', 'comment_ids']) {
    my ($stash, $key) = @$pair;
    next if !defined(my $id = $self->stash($stash));
    $params->{$key} = [uniq($id, @{$params->{$key} || []})];
  }

  # The legacy server converted new_since to the database timezone.
  if (defined $params->{new_since}) {
    my $converted = datetime_from($params->{new_since}, Bugzilla->local_timezone)
      // return $self->user_error('illegal_date', {date => $params->{new_since}});
    $params->{new_since} = $converted->ymd() . ' ' . $converted->hms();
  }

  my $bug_ids      = $params->{ids}         || [];
  my $comment_ids  = $params->{comment_ids} || [];
  my $skip_private = $params->{skip_private} ? 1 : 0;

  Bugzilla->switch_to_shadow_db();

  unless ($user->id) {
    Bugzilla->check_rate_limit("get_comments", remote_ip());
  }

  if ($skip_private) {

    # Cache permissions for bugs. This highly reduces the number of calls to the DB.
    # visible_bugs() is only able to handle bug IDs, so we have to skip aliases.
    my @int = grep { $_ =~ /^\d+$/ } @$bug_ids;
    $user->visible_bugs(\@int);
  }

  my %bugs;
  my @bug_comments;
  foreach my $bug_id (@$bug_ids) {
    my $bug;

    if ($skip_private) {
      $bug = Bugzilla::Bug->new({id => $bug_id, cache => 1});
      next if $bug->error || !$user->can_see_bug($bug->id);
    }
    else {
      $bug = Bugzilla::Bug->check($bug_id);
    }

    # We want the API to always return comments in the same order.
    my $comments = $bug->comments(
      {order => 'oldest_to_newest', after => $params->{new_since}});
    push(@bug_comments, [$bug, $comments]);
  }

  # Preload every requested bug's comments in one query, otherwise a bulk
  # request would run one aggregation query per bug.
  Bugzilla::API::V1::Util->preload_comment_edit_info([map { @{$_->[1]} } @bug_comments]);

  my $want_collapsed = Bugzilla::API::V1::Util->wants_collapsed_comments($params);

  foreach my $bug_comment (@bug_comments) {
    my ($bug, $comments) = @$bug_comment;
    my @result;
    foreach my $comment (@$comments) {
      next if $comment->is_private && !$user->is_insider;
      next if $comment->collapsed  && !$want_collapsed;
      push(@result, Bugzilla::API::V1::Util->comment_to_hash($comment, $params));
    }
    $bugs{$bug->id}{'comments'} = \@result;
  }

  my %comments;
  if (scalar @$comment_ids) {
    my @ids          = map { trim($_) } @$comment_ids;
    my $comment_data = Bugzilla::Comment->new_from_list(\@ids);

    # See if we were passed any invalid comment ids.
    my %got_ids = map { $_->id => 1 } @$comment_data;
    foreach my $comment_id (@ids) {
      if (!$got_ids{$comment_id}) {
        return $self->user_error('comment_id_invalid', {id => $comment_id});
      }
    }

    # Now make sure that we can see all the associated bugs.
    my %got_bug_ids = map { $_->bug_id => 1 } @$comment_data;
    Bugzilla::Bug->check($_) foreach (keys %got_bug_ids);

    Bugzilla::API::V1::Util->preload_comment_edit_info($comment_data);

    foreach my $comment (@$comment_data) {
      if ($comment->is_private && !$user->is_insider) {
        return $self->user_error('comment_is_private', {id => $comment->id});
      }
      $comments{$comment->id}
        = Bugzilla::API::V1::Util->comment_to_hash($comment, $params);
    }
  }

  return $self->render(json => {bugs => \%bugs, comments => \%comments});
}

# POST /bug/<id>/comment
sub add_comment {
  my ($self) = @_;

  # BMO: Don't allow updating of bugs if disabled
  return Bugzilla::API::V1::Util->updates_disabled($self) if Bugzilla->params->{disable_bug_updates};

  # The user must login in order add a comment
  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $error, $vars) = $self->_request_params;
  return $self->user_error($error, $vars) if $error;

  # Check parameters
  my $comment = $params->{comment};
  (defined $comment && trim($comment) ne '')
    || return $self->code_error('param_required', {param => 'comment'});

  my $bug = Bugzilla::Bug->check($params->{id});

  $user->can_edit_product($bug->product_id)
    || return $self->user_error("product_edit_denied",
    {product => $bug->product});

  # Backwards-compatibility for versions before 3.6
  if (defined $params->{private}) {
    $params->{is_private} = delete $params->{private};
  }

  # Append comment
  $bug->add_comment(
    $comment,
    {
      isprivate   => $params->{is_private},
      work_time   => $params->{work_time},
      is_markdown => (
        defined $params->{is_markdown}
        ? ($params->{is_markdown}           ? 1 : 0)
        : (Bugzilla->params->{use_markdown} ? 1 : 0)
      )
    }
  );

  # Add comment tags
  $bug->set_all({comment_tags => $params->{comment_tags}})
    if defined $params->{comment_tags};

  $bug->update();

  my $new_comment_id = $bug->{added_comments}[0]->id;

  # Send mail.
  Bugzilla::BugMail::Send($bug->bug_id, {changer => $user});

  return $self->render(
    json   => {id => $self->type('int', $new_comment_id)},
    status => 201
  );
}

# POST /bug/comment/render
sub render_comment {
  my ($self) = @_;

  $self->bugzilla->login;

  my ($params, $error, $vars) = $self->_request_params;
  return $self->user_error($error, $vars) if $error;

  unless (defined $params->{text}) {
    return $self->code_error('params_required',
      {function => 'Bug.render_comment', params => ['text']});
  }

  Bugzilla->switch_to_shadow_db();
  my $bug = $params->{id} ? Bugzilla::Bug->check($params->{id}) : undef;

  my $html
    = Bugzilla->params->{use_markdown}
    ? Bugzilla->markdown->render_html($params->{text}, $bug)
    : Bugzilla::Template::quoteUrls($params->{text}, $bug);

  # Extensions can add params and return values. When id is given, the Needinfo
  # extension accepts include_mentions and mention_is_private and returns
  # mentions: the users that saving the comment on that bug would CC and
  # needinfo, shown by the comment preview.
  my $result = {html => $html};
  Bugzilla::Hook::process('webservice_bug_render_comment',
    {webservice => $self, bug => $bug, params => $params, result => $result});

  return $self->render(json => $result);
}

# GET /bug/comment/<comment_id>/reactions
sub get_comment_reactions {
  my ($self) = @_;

  Bugzilla->params->{use_comment_reactions}
    || return $self->user_error('comment_reaction_disabled');

  $self->bugzilla->login;

  my ($comment, undef, $responded)
    = $self->_visible_comment('Bug.get_comment_reactions');
  return                           if $responded;
  return $self->render(json => []) if !$comment;

  return $self->render(
    json => $self->_get_comment_reactions_with_users($comment));
}

# PUT /bug/comment/<comment_id>/reactions
sub update_comment_reactions {
  my ($self) = @_;

  Bugzilla->params->{use_comment_reactions}
    || return $self->user_error('comment_reaction_disabled');

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($comment, $params, $responded)
    = $self->_visible_comment('Bug.update_comment_reactions');
  return                           if $responded;
  return $self->render(json => []) if !$comment;

  if ($comment->bug->is_closed_for({months => 3})) {
    return $self->user_error('comment_reaction_closed');
  }

  if ($comment->bug->restrict_comments
    && !$user->in_group(Bugzilla->params->{'restrict_comments_group'}))
  {
    return $self->user_error('comment_reaction_restricted');
  }

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction();
  foreach my $reaction (@{$params->{add} || []}) {
    $comment->add_reaction($reaction);
  }
  foreach my $reaction (@{$params->{remove} || []}) {
    $comment->remove_reaction($reaction);
  }
  $comment->update();
  $dbh->bz_commit_transaction();

  return $self->render(
    json => $self->_get_comment_reactions_with_users($comment));
}

# PUT /bug/comment/<comment_id>/tags
sub update_comment_tags {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');
  Bugzilla->params->{'comment_taggers_group'}
    || return $self->user_error("comment_tag_disabled");
  $user->can_tag_comments || return $self->user_error(
    "auth_failure",
    {
      group  => Bugzilla->params->{'comment_taggers_group'},
      action => "update",
      object => "comment_tags"
    }
  );

  my ($comment, $params, $responded)
    = $self->_visible_comment('Bug.update_comment_tags');
  return                           if $responded;
  return $self->render(json => []) if !$comment;

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

  return $self->render(json => $comment->tags);
}

# GET /bug/comment/tags/<query>
sub search_comment_tags {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');
  Bugzilla->params->{'comment_taggers_group'}
    || return $self->user_error("comment_tag_disabled");
  $user->can_tag_comments || return $self->user_error(
    "auth_failure",
    {
      group  => Bugzilla->params->{'comment_taggers_group'},
      action => "search",
      object => "comment_tags"
    }
  );

  my $query = $self->param('query');
  my $limit = $self->param('limit') || 7;
  detaint_natural($limit)
    || return $self->code_error('param_must_be_numeric',
    {param => 'limit', function => 'Bug.search_comment_tags'});

  my $tags
    = Bugzilla::Comment::TagWeights->match({
    WHERE => {'tag LIKE ?' => "\%$query\%",}, LIMIT => $limit,
    });
  return $self->render(json => [map { $_->tag } @$tags]);
}

# Parameters of a POST or PUT: the query string and the request body, as on
# the legacy REST server. The id in the path is only used when neither of
# them has one.
sub _request_params {
  my ($self) = @_;

  my ($params, $error)
    = merge_request_params($self, [qw(add remove comment_tags)]);
  return (undef, $error) if $error;

  $params->{$_} //= $self->stash($_) for qw(id comment_id);

  # A bug id is a single value. A hash here would reach Bugzilla::Bug->check()
  # as a set of object conditions. (A comment_id hash fails detaint_natural.)
  return (undef, 'invalid_params', {type_error => 'id must be a single value'})
    if ref $params->{id};

  return ($params, undef);
}

# Loads the comment named by comment_id and checks that the user can see it.
# Returns ($comment, $params, $responded). $responded is true when an error
# response has already been rendered (the error helpers return 0, so their
# result can't be used for this). An unknown comment gives an undef $comment:
# the legacy methods returned an empty list for it.
sub _visible_comment {
  my ($self, $function) = @_;
  my $user = Bugzilla->user;

  my ($params, $error, $vars) = $self->_request_params;
  if ($error) {
    $self->user_error($error, $vars);
    return (undef, undef, 1);
  }

  my $comment_id = $params->{comment_id};
  if (!detaint_natural($comment_id)) {
    $self->code_error('param_must_be_numeric',
      {function => $function, param => 'comment_id'});
    return (undef, undef, 1);
  }
  my $comment = Bugzilla::Comment->new($comment_id) || return (undef, $params, 0);

  $comment->bug->check_is_visible();
  if ($comment->is_private && !$user->is_insider) {
    $self->user_error('comment_is_private', {id => $comment_id});
    return (undef, undef, 1);
  }

  return ($comment, $params, 0);
}

sub _get_comment_reactions_with_users {
  my ($self, $comment) = @_;
  my $reactions_with_users = $comment->reactions_with_users();

  foreach my $reaction (keys %$reactions_with_users) {
    $reactions_with_users->{$reaction}
      = [map { Bugzilla::API::V1::Util->user_to_hash($_) }
        @{$reactions_with_users->{$reaction}}];
  }

  return $reactions_with_users;
}

1;
