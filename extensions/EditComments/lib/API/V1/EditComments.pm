# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::EditComments::API::V1::EditComments;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Comment;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Template;
use Bugzilla::Util          qw(trim);
use Bugzilla::API::V1::Util qw(coerce_booleans merge_request_params
  render_options);

sub setup_routes {
  my ($class, $r) = @_;
  my $to = 'EditComments::API::V1::EditComments#';
  $r->get('/editcomments/comment')->to($to . 'comments');
  $r->get('/editcomments/comment/:comment_id' => [comment_id => qr/\d+/])
    ->to($to . 'comments');
  $r->put('/editcomments/comment/:comment_id' => [comment_id => qr/\d+/])
    ->to($to . 'update_comment');
  $r->put('/editcomments/revision')->to($to . 'modify_revision');

  $r->options('/editcomments/comment')
    ->to(cb => \&render_options, allow => 'GET');
  $r->options('/editcomments/comment/:comment_id' => [comment_id => qr/\d+/])
    ->to(cb => \&render_options, allow => 'GET, PUT');
  $r->options('/editcomments/revision')
    ->to(cb => \&render_options, allow => 'PUT');
}

# Request params, with the comment ID from the path if there is one.
sub _params {
  my ($self,   $lists) = @_;
  my ($params, $error) = merge_request_params($self, $lists);
  return (undef, $error) if $error;
  if (defined(my $id = $self->stash('comment_id'))) {
    $params->{comment_id}  = $id;
    $params->{comment_ids} = [$id] if $lists;
  }
  return ($params, undef);
}

# GET /editcomments/comment?comment_ids=<id>&comment_ids=<id>...
# GET /editcomments/comment/<id>
#
# Returns {comments => {<id> => <raw text>}}.
sub comments {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;
  Bugzilla->switch_to_shadow_db();

  my ($params, $error) = $self->_params(['comment_ids']);
  return $self->user_error($error) if $error;

  if (!@{$params->{comment_ids} || []}) {
    ThrowCodeError('param_required',
      {function => 'Bug.comments', param => 'comment_ids'});
  }

  my @ids          = map { trim($_) } @{$params->{comment_ids}};
  my $comment_data = Bugzilla::Comment->new_from_list(\@ids);

  # See if we were passed any invalid comment ids.
  my %got_ids = map { $_->id => 1 } @$comment_data;
  foreach my $comment_id (@ids) {
    if (!$got_ids{$comment_id}) {
      ThrowUserError('comment_id_invalid', {id => $comment_id});
    }
  }

  # Now make sure that we can see all the associated bugs.
  my %got_bug_ids = map { $_->bug_id => 1 } @$comment_data;
  $user->visible_bugs([keys %got_bug_ids]);    # preload cache for visibility check
  Bugzilla::Bug->check($_) foreach (keys %got_bug_ids);

  my %comments;
  foreach my $comment (@$comment_data) {
    if ($comment->is_private && !$user->is_insider) {
      ThrowUserError('comment_is_private', {id => $comment->id});
    }
    $comments{$comment->id} = $comment->body;
  }

  return $self->render(json => {comments => \%comments});
}

# PUT /editcomments/comment/<id>
#
# Replaces the comment's text. Params:
#   new_comment  the new text
#   is_hidden    hide the old revision (edit_comments_admins_group only)
# Returns {text, html, count}, count being the number of revisions.
sub update_comment {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $error) = $self->_params;
  return $self->user_error($error) if $error;
  if ($error = coerce_booleans($params, 'is_hidden')) {
    return $self->user_error('invalid_params', {type_error => $error});
  }
  my $comment_id = $params->{comment_id};

  ThrowCodeError('param_required',
    {function => 'EditComments.update_comment', param => 'new_comment'})
    unless defined $params->{new_comment} && trim($params->{new_comment}) ne '';

  my $comment = Bugzilla::Comment->new($comment_id);

  # Validate comment visibility
  ThrowUserError('comment_id_invalid', {id => $comment_id}) unless $comment;
  ThrowUserError('comment_is_private', {id => $comment->id})
    unless $user->is_insider || !$comment->is_private;

  my $bug = $comment->bug;

  # Validate bug visibility
  $bug->check_is_visible();

  # Check if user can edit this comment.
  ThrowUserError('auth_failure', {action => 'view', object => 'editcomments'})
    unless $comment->is_editable_by($user);

  my $old_comment = $comment->body;
  my $new_comment = $comment->_check_thetext($params->{new_comment});

  # Make sure there is any change in the comment
  ThrowCodeError('param_no_changes',
    {function => 'EditComments.update_comment', param => 'new_comment'})
    if $old_comment eq $new_comment;

  my $dbh       = Bugzilla->dbh;
  my $timestamp = $dbh->selectrow_array('SELECT NOW()');

  # edit_comments_admins_group members can hide comment revisions where needed
  my $is_hidden = $user->is_edit_comments_admin && $params->{is_hidden} ? 1 : 0;

  $comment->update_text({
    text          => $new_comment,
    timestamp     => $timestamp,
    is_hidden     => $is_hidden,
    sync_fulltext => 1,
  });

  # Render what the bug page shows, which can differ from the stored text: the
  # comment_body_full hook lets extensions hide part of it (eg. Hackbot's front
  # matter).
  my $body = $comment->body_full({exclude_attachment => 1});
  my $html
    = $comment->is_markdown && Bugzilla->params->{use_markdown}
    ? Bugzilla->markdown->render_html($body, $bug)
    : Bugzilla::Template::quoteUrls($body, $bug);

  my $count
    = $dbh->selectrow_array(
    'SELECT COUNT(*) FROM longdescs_activity WHERE comment_id = ?',
    undef, $comment_id);

  return $self->render(
    json => {
      text  => Bugzilla::API::V1::Util->type('string', $new_comment),
      html  => Bugzilla::API::V1::Util->type('string', $html),
      count => Bugzilla::API::V1::Util->type('int',    $count),
    }
  );
}

# PUT /editcomments/revision
#
# Hides or shows a revision of a comment (edit_comments_admins_group only).
# Params: comment_id, change_when (YYYY-MM-DD HH:MM:SS), is_hidden.
# Returns {change_when, is_hidden}.
sub modify_revision {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # Only allow edit_comments_admins_group members to modify revisions
  ThrowUserError(
    'auth_failure',
    {
      group  => 'edit_comments_admins_group',
      action => 'view',
      object => 'editcomments'
    }
  ) unless $user->is_edit_comments_admin;

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;
  if ($error = coerce_booleans($params, 'is_hidden')) {
    return $self->user_error('invalid_params', {type_error => $error});
  }

  my $comment_id
    = (defined $params->{comment_id} && $params->{comment_id} =~ /^(\d+)$/)
    ? $1
    : undef;
  my $change_when
    = (defined $params->{change_when}
      && $params->{change_when} =~ /^(\d{4}-\d{2}-\d{2}\ \d{2}:\d{2}:\d{2})$/)
    ? $1
    : undef;
  my $is_hidden = $params->{is_hidden} ? 1 : 0;

  # Validate parameters
  ThrowCodeError('param_required',
    {function => 'EditComments.modify_revision', param => 'comment_id'})
    unless defined $comment_id;
  ThrowCodeError('param_required',
    {function => 'EditComments.modify_revision', param => 'change_when'})
    unless defined $change_when;

  # Update revision visibility
  Bugzilla->dbh->do(
    'UPDATE longdescs_activity SET is_hidden = ? WHERE comment_id = ? AND change_when = ?',
    undef, $is_hidden, $comment_id, $change_when
  );

  # Clear memcached entry of comment 0 authors
  Bugzilla->memcached->clear({key => 'c0:' . $comment_id});

  return $self->render(
    json => {
      change_when => Bugzilla::API::V1::Util->type('dateTime', $change_when),
      is_hidden   => Bugzilla::API::V1::Util->type('boolean',  $is_hidden),
    }
  );
}

1;
