# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::InvalidBugHelper::API::V1::InvalidBugHelper;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::API::V1::Util qw(coerce_booleans merge_request_params);

sub setup_routes {
  my ($class, $r) = @_;
  $r->post('/invalid_bug_helper/close/:id' => [id => qr/\d+/])
    ->to('InvalidBugHelper::API::V1::InvalidBugHelper#close_as_invalid');
}

# POST /invalid_bug_helper/close/<id>
#
# Moves the bug to Invalid Bugs :: General, resolves it as INVALID, clears its
# needinfo flags and posts the warning comment. Editbugs members only. Params:
#   mark_as_spam  also tag the reporter's comments as spam
# Returns {id, product, status}.
sub close_as_invalid {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');
  my $dbh = Bugzilla->dbh;

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  if ($error = coerce_booleans($params, 'mark_as_spam')) {
    return $self->user_error('invalid_params', {type_error => $error});
  }

  $user->in_group('editbugs')
    || ThrowUserError('auth_failure',
    {group => 'editbugs', action => 'update', object => 'bug'});

  my $bug = Bugzilla::Bug->check({id => $self->param('id')});

  if ($bug->reporter->in_group('editbugs')) {
    ThrowUserError('invalid_bug_reporter_is_trusted', {bug => $bug});
  }

  # Block non-members from closing bugs with mandatory security groups.
  foreach my $group (@{$bug->groups_in}) {
    my $gc = $bug->product_obj->group_controls->{$group->id};
    if ( $gc
      && $gc->{membercontrol} == CONTROLMAPMANDATORY
      && !$user->in_group($group->name))
    {
      ThrowUserError('auth_failure',
        {group => $group->name, action => 'modify', object => 'bug'});
    }
  }

  if ( $bug->bug_status eq 'RESOLVED'
    || $bug->bug_status eq 'VERIFIED'
    || $bug->product eq 'Invalid Bugs')
  {
    ThrowUserError('bug_status_unresolvable', {bug => $bug});
  }

  # Snapshot reporter comments, flags, and groups before any mutations.
  my @reporter_comments
    = grep { $_->author->id == $bug->reporter->id } @{$bug->comments};
  my @clear_flags = map { {id => $_->id, status => 'X'} }
    grep { $_->type->name eq 'needinfo' } @{$bug->flags};

  my $warning_text = Bugzilla->params->{invalidbughelper_warning_text}
    || 'This bug has been marked as invalid.';

  $dbh->bz_start_transaction();

  # Clear all needinfo flags.
  $bug->set_flags(\@clear_flags, []) if @clear_flags;

  # Relocate the bug, resolve it, reset ownership, and post the warning comment.
  $bug->set_all({
    product           => 'Invalid Bugs',
    component         => 'General',
    bug_status        => 'RESOLVED',
    resolution        => 'INVALID',
    reset_assigned_to => 1,
    reset_qa_contact  => 1,
    comment           => {body => $warning_text},
  });

  # Non-mandatory security group stripping is handled by _set_product (called
  # via set_all above).
  $bug->update();

  # Only tag reporter comments as spam when explicitly requested.
  if ($params->{mark_as_spam} && $user->can_tag_comments) {
    foreach my $comment (@reporter_comments) {
      $comment->add_tag('spam');
      $comment->update();
    }
  }

  $dbh->bz_commit_transaction();

  # Flag mail is part of bugmail, so the requesters of the cleared needinfos
  # are told now rather than with the bug's next change.
  Bugzilla::BugMail::Send($bug->id, {changer => $user});

  return $self->render(
    json => {
      id      => Bugzilla::API::V1::Util->type('int',    $bug->id),
      product => Bugzilla::API::V1::Util->type('string', $bug->product),
      status  => Bugzilla::API::V1::Util->type('string', $bug->bug_status),
    }
  );
}

1;
