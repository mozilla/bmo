# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz::Util;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::Types qw(:types);
use Bugzilla::Util qw(mojo_user_agent trim);
use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Types qw(:types);

use List::Util qw(any first none);
use Try::Tiny;
use Type::Params qw( compile );
use Type::Utils;
use Types::Standard qw( :types );
use Mojo::JSON      qw(encode_json);

use base qw(Exporter);

our @EXPORT = qw(
  create_revision_attachment
  get_attachment_revisions
  get_bug_role_phids
  intersect
  is_attachment_phab_revision
  is_auto_assign_excluded
  is_bug_assigned
  remove_noop_transactions
  request
  set_attachment_approval_flags
  set_bug_assignee
  set_phab_user
  set_reviewer_rotation
  set_intermittent_reviewers
  should_auto_assign_revision
);

use constant LEGACY_APPROVAL_MAPPING => {
  'firefox-beta'    => 'beta',
  'firefox-release' => 'release',
  'firefox-esr115'  => 'esr115',
  'firefox-esr128'  => 'esr128',
  'firefox-esr140'  => 'esr140',
  'firefox-esr153'  => 'esr153',
};

# Set approval flags on Phabricator revision bug attachments.
sub set_attachment_approval_flags {
  my ($attachment, $revision, $phab_user, $is_new) = @_;
  my $bmo_user = $phab_user->bugzilla_user;

  my $revision_status_flag_map = {
    'abandoned'       => '-',
    'accepted'        => '+',
    'accepted-prior'  => '+',
    'changes-planned' => 'X',
    'draft'           => '?',
    'needs-review'    => '?',
    'needs-revision'  => '-',
  };

  # Find the current review status of the revision changer
  my $status          = undef;
  my $reviewer_status = undef;

  if ($is_new) {
    $reviewer_status = $revision->status;
    $status          = $revision_status_flag_map->{$reviewer_status};
  }
  else {
    foreach my $reviewer (@{$revision->reviews}) {
      if ($reviewer->{user}->id == $phab_user->id) {
        $reviewer_status = $reviewer->{status};
        $status          = $revision_status_flag_map->{$reviewer_status};
        last;
      }
    }
  }

  if (!$status) {
    INFO( "Approval flag status not found for revision status '"
        . $reviewer_status
        . "'");
    return;
  }

  # The repo short name is the appropriate value that aligns with flag names.
  my $repo_name = $revision->repository->short_name;

  # With the move to git some repository short names in Phabricator changed but
  # we want to use the old approval flags so we map the new names to the old if
  # they exist
  $repo_name = LEGACY_APPROVAL_MAPPING->{$repo_name} || $repo_name;

  my $approval_flag_name = "approval-mozilla-$repo_name";

  # Skip if the flag type is explicitly disabled globally (bug 1990568),
  # but still let `set_flags` fail later if it is enabled yet missing from
  # the bug's product/component.
  my $approval_flag = Bugzilla::FlagType->new({name => $approval_flag_name});
  if ($approval_flag && !$approval_flag->is_active) {
    INFO("Approval flag `$approval_flag_name` is disabled. Skipping.");
    return;
  }

  my @old_flags;
  my @new_flags;

  INFO( 'Setting revision D'
      . $revision->id
      . ' with '
      . $reviewer_status
      . ' status to '
      . $approval_flag_name
      . $status);

  # Find the current approval flag state if it exists.
  foreach my $flag (@{$attachment->flags}) {

    # Ignore for all flags except the approval flag.
    next if $flag->name ne $approval_flag_name;

    # Set the flag to it's new status. If it already has that status,
    # it will be a non-change. We also need to check to make sure the
    # flag change is allowed.
    if (!$bmo_user->can_change_flag($flag->type, $flag->status, $status)) {
      INFO(
        "Unable to set existing `$approval_flag_name` flag to `$status` due to permissions."
      );
      return;
    }

    # If setting to + then the Phabricator user needs to be a release manager.
    if (($status eq '+' || $status eq '-') && !$phab_user->is_release_manager) {
      INFO(
        "Unable to set existing `$approval_flag_name` flag to `$status` due to not being a release manager."
      );
      return;
    }

    INFO("Set existing `$approval_flag_name` flag to `$status`.");
    push @old_flags, {id => $flag->id, status => $status};
    last;
  }

  # If we didn't find an existing approval flag to update, add it now.
  # Also check to make sure we have permission to create the flag.
  if (!@old_flags && $status ne 'X') {
    if ($approval_flag) {

  # If setting to + then at least one accepted reviewer needs to be a release manager.
      if ($status eq '+' && !$phab_user->is_release_manager) {
        INFO(
          "Unable to create new `$approval_flag_name` flag with status `$status` due to not being accepted by a release manager."
        );
        return;
      }

      if ($bmo_user->can_change_flag($approval_flag, 'X', $status)) {
        INFO("Creating new `$approval_flag_name` flag with status `$status`");
        push @new_flags,
          {setter => $bmo_user, status => $status, type_id => $approval_flag->id,};
      }
      else {
        INFO(
          "Unable to create new `$approval_flag_name` flag with status `$status` due to permissions."
        );
      }
    }
    else {
      INFO("Approval flag $approval_flag_name type not found");
    }
  }

  $attachment->set_flags(\@old_flags, \@new_flags);
}

sub create_revision_attachment {
  state $check = compile(Bug, Revision, Str, User);
  my ($bug, $revision, $timestamp, $submitter) = $check->(@_);

  my $phab_base_uri = Bugzilla->params->{phabricator_base_uri};
  ThrowUserError('invalid_phabricator_uri') unless $phab_base_uri;

  my $revision_uri = $phab_base_uri . "D" . $revision->id;

  # Check for previous attachment with same revision id.
  # If one matches then return it instead. This is fine as
  # BMO does not contain actual diff content.
  my @review_attachments
    = grep { is_attachment_phab_revision($_) } @{$bug->attachments};
  my $attachment = first { trim($_->data) eq $revision_uri } @review_attachments;

  if (!defined $attachment) {
    # No attachment is present, so we can now create new one

    if (!$timestamp) {
      ($timestamp) = Bugzilla->dbh->selectrow_array("SELECT NOW()");
    }

    # If submitter, then switch to that user when creating attachment
    local $submitter->{groups} = [Bugzilla::Group->get_all]; # We need to always be able to add attachment
    my $restore_prev_user = Bugzilla->set_user($submitter, scope_guard => 1);

    # Users cannot normally create attachments with text/x-phabricator-request content type.
    # So we need to set an override to allow it for this attachment.
    my $request_cache = Bugzilla->request_cache;
    local $request_cache->{allow_phab_revision_attachment} = 1;

    my $new_attach_description = $revision->secured_title;

    $attachment = Bugzilla::Attachment->create({
      bug         => $bug,
      creation_ts => $timestamp,
      data        => $revision_uri,
      description => $new_attach_description,
      filename    => 'phabricator-D' . $revision->id . '-url.txt',
      ispatch     => 0,
      isprivate   => 0,
      mimetype    => PHAB_CONTENT_TYPE,
    });

    # Insert a comment about the new attachment into the database.
    $bug->add_comment(
      $revision->summary,
      {
        type        => CMT_ATTACHMENT_CREATED,
        extra_data  => $attachment->id,
        is_markdown => (Bugzilla->params->{use_markdown} ? 1 : 0)
      }
    );

    INFO('New attachment ' . $attachment->id . ' created');
  }
  else {
    INFO('Existing attachment ' . $attachment->id . ' found');
  }

  return $attachment;
}

sub intersect {
  my ($list1, $list2) = @_;
  my %e = map { $_ => undef } @{$list1};
  return grep { exists($e{$_}) } @{$list2};
}

sub get_bug_role_phids {
  state $check = compile(Bug);
  my ($bug) = $check->(@_);

  my @bug_users = ($bug->reporter);
  push(@bug_users, $bug->assigned_to) if is_bug_assigned($bug);
  push(@bug_users, $bug->qa_contact)  if $bug->qa_contact;
  push(@bug_users, @{$bug->cc_users}) if @{$bug->cc_users};

  my $phab_users = Bugzilla::Extension::PhabBugz::User->match(
    {ids => [map { $_->id } @bug_users]});

  return [map { $_->phid } @{$phab_users}];
}

sub is_bug_assigned {
  return $_[0]->assigned_to->email ne 'nobody@mozilla.org';
}

# Returns true if the given Bugzilla::User's login is present in the
# `phabricator_auto_assign_exclude_list` parameter. This is used to prevent
# automatically assigning a bug to automation accounts (e.g. Hackbot) that
# author Phabricator revisions.
sub is_auto_assign_excluded {
  my ($user) = @_;
  my $list = Bugzilla->params->{phabricator_auto_assign_exclude_list};
  return 0 unless $list;
  my $login = lc $user->login;
  return any { lc(trim($_)) eq $login } split /[\s,]+/, $list;
}

# Decide whether a Phabricator revision change should auto-assign its bug to
# the current revision author. Kept as a pure predicate (no Bugzilla state) so
# the assignment logic can be unit tested. Expects a hashref with:
#   bug_assigned            - bug already has a real assignee
#   is_abandoned            - revision status is 'abandoned'
#   submitter_excluded      - current author is in the exclude list
#   leave_open_intermittent - bug has both leave-open + intermittent-failure
#   has_reviews             - revision has reviewers assigned
#   is_commandeer           - this change is a commandeer transaction
#   prior_author_excluded   - the original revision author was excluded
# A revision normally auto-assigns only once it has reviewers. A commandeer is
# allowed to bypass the reviewer requirement, but only when the revision was
# originally authored by an excluded account (e.g. Hackbot); otherwise ordinary
# commandeers of reviewer-less revisions would start auto-assigning bugs.
sub should_auto_assign_revision {
  my ($args) = @_;
  return 0 if $args->{bug_assigned};
  return 0 if $args->{is_abandoned};
  return 0 if $args->{submitter_excluded};
  return 0 if $args->{leave_open_intermittent};
  return 1 if $args->{has_reviews};
  return 1 if $args->{is_commandeer} && $args->{prior_author_excluded};
  return 0;
}

# Assign the bug to the current revision author when appropriate (see
# should_auto_assign_revision for the rules). The caller is responsible for
# committing the change via $bug->update. `$story_text` is the Phabricator feed
# story text, used to detect commandeer transactions.
sub set_bug_assignee {
  my ($revision, $bug, $story_text) = @_;
  $story_text //= '';

  # Locate the BMO attachment representing this revision so we can tell who
  # originally authored it. The attacher is recorded when the attachment is
  # created and persists across a commandeer, so it identifies the original
  # (possibly excluded, e.g. Hackbot) author even after the revision author
  # has changed.
  my $revision_uri = Bugzilla->params->{phabricator_base_uri} . 'D' . $revision->id;
  my $attachment = first {
    is_attachment_phab_revision($_) && trim($_->data) eq $revision_uri
  }
  @{$bug->attachments};

  my $submitter = $revision->author->bugzilla_user;

  return
    unless should_auto_assign_revision({
    bug_assigned       => is_bug_assigned($bug),
    is_abandoned       => ($revision->status eq 'abandoned'),
    submitter_excluded => is_auto_assign_excluded($submitter),
    has_reviews        => scalar @{$revision->reviews},
    is_commandeer      => ($story_text =~ /\s+commandeered\s+D\d+/ ? 1 : 0),
    prior_author_excluded =>
      ($attachment ? is_auto_assign_excluded($attachment->attacher) : 0),
    leave_open_intermittent => (
           $bug->has_keyword('leave-open')
        && $bug->has_keyword('intermittent-failure')
    ),
    });

  INFO('Assigning bug ' . $bug->id . ' to ' . $submitter->email);
  $bug->set_assigned_to($submitter);
  if (any { $bug->status->name eq $_ } 'NEW', 'UNCONFIRMED') {
    INFO('Setting bug ' . $bug->id . ' to ASSIGNED');
    $bug->set_bug_status('ASSIGNED');
  }

  return;
}

sub is_attachment_phab_revision {
  state $check = compile(Attachment);
  my ($attachment) = $check->(@_);
  return $attachment->contenttype eq PHAB_CONTENT_TYPE;
}

sub get_attachment_revisions {
  state $check = compile(Bug);
  my ($bug) = $check->(@_);

  my @attachments
    = grep { is_attachment_phab_revision($_) } @{$bug->attachments()};

  return unless @attachments;

  my @revision_ids;
  foreach my $attachment (@attachments) {
    my ($revision_id) = ($attachment->filename =~ PHAB_ATTACHMENT_PATTERN);
    next if !$revision_id;
    push(@revision_ids, int($revision_id));
  }

  return unless @revision_ids;

  my @revisions;
  foreach my $revision_id (@revision_ids) {
    my $revision = Bugzilla::Extension::PhabBugz::Revision->new_from_query(
      {ids => [$revision_id]});
    push @revisions, $revision if $revision;
  }

  return \@revisions;
}

# Drops add/remove transactions with no values from a Conduit edit. A `.set`
# with an empty list is kept as it clears the field.
sub remove_noop_transactions {
  my ($transactions) = @_;
  return [
    grep {
      !(   $_->{type} =~ /\.(?:add|remove)$/
        && ref $_->{value} eq 'ARRAY'
        && !@{$_->{value}})
    } @$transactions
  ];
}

sub request {
  state $check = compile(Str, HashRef, Optional[Bool]);
  my ($method, $data, $no_die) = $check->(@_);
  my $request_cache = Bugzilla->request_cache;
  my $params        = Bugzilla->params;
  my $ua            = $request_cache->{phabricator_ua} ||= mojo_user_agent();

  my $phab_api_key = $params->{phabricator_api_key};
  ThrowUserError('invalid_phabricator_api_key') unless $phab_api_key;
  my $phab_base_uri = $params->{phabricator_base_uri};
  ThrowUserError('invalid_phabricator_uri') unless $phab_base_uri;

  my $full_uri = $phab_base_uri . '/api/' . $method;

  $data->{__conduit__} = {token => $phab_api_key};

  my $response
    = $ua->post($full_uri => form => {params => encode_json($data)})->result;
  ThrowCodeError('phabricator_api_error', {reason => $response->message})
    if $response->is_error;

  my $result = $response->json;
  ThrowCodeError('phabricator_api_error', {reason => 'JSON decode failure'})
    if !defined($result);

  if ($result->{error_code} && !$no_die) {
    ThrowCodeError('phabricator_api_error',
      {code => $result->{error_code}, reason => $result->{error_info}});
  }

  return $result;
}

sub set_phab_user {
  my $user = Bugzilla::User->new({name => PHAB_AUTOMATION_USER});
  $user->{groups} = [Bugzilla::Group->get_all];

  return Bugzilla->set_user($user, scope_guard => 1);
}

sub set_reviewer_rotation {
  my ($revision) = @_;

  INFO('D' . $revision->id . ': Setting reviewer rotation');

  # Load a fresh version of the revision with Heralds changes.
  $revision = Bugzilla::Extension::PhabBugz::Revision->new_from_query(
    {phids => [$revision->phid]});

  # Map of phids to blocking status
  my $is_blocking = {};

# Find out what the reviewer groups (if any) are. If the revision has a reviewer
# group set, normally it ends in "-reviewer-rotation". Normally Herald will set this
# if certain conditions are met. If there are no review rotation groups, then do nothing.
  my @review_projects = get_review_rotation_projects($revision, $is_blocking);

  if (!@review_projects) {
    INFO('Reviewer rotation projects not found. Returning.');
    return;
  }

  # After project reviewers, we also need to get a list of individual reviewers
  my @review_users = get_review_users($revision, $is_blocking);

  # If the revision is part of a stack, grab a list of current reviewers
  # and if one of the project members is a reviewer, then assign the same reviewer
  my @stack_reviewers = get_stack_reviewers($revision, $is_blocking);

  # Once the reviewer rotation groups are determined, query Phabricator for
  # list of group members for each and sort them by user ID descending.
PROJECT: foreach my $project (@review_projects) {
    INFO('Processing review project: ' . $project->name);

    # Sort the project members so we always the same order as best we can.
    my @project_members = sort { $a->id <=> $b->id } @{$project->members};

    # If there are no members then we can't do anything and should just skip
    if (!@project_members) {
      INFO('No project members found for ' . $project->name . '. Skipping.');
      next;
    }

    INFO('Sorted project members found: '
        . (join ', ', map { $_->name } @project_members));

    # Find the last selected reviewer for the rotation group, if one exists.
    my $last_reviewer_phid = find_last_reviewer_phid($project);
    INFO('Last reviewer phid found: '
        . ($last_reviewer_phid ? $last_reviewer_phid : 'None'));

    # If a last reviewer exists, we want to rotate the list to where the
    # last reviewer is at the front of the list while maintaining order.
    # move them to the front of the member list
    @project_members = rotate_reviewer_list(\@project_members, $last_reviewer_phid);

    # If there is only one member, then guess what? You are always getting it.
    if (scalar @project_members == 1) {
      my $lone_reviewer = $project_members[0];

      if ( $lone_reviewer->phid ne $revision->author->phid
        && $lone_reviewer->bugzilla_user->can_see_bug($revision->bug->id)
        && $lone_reviewer->bugzilla_user->settings->{block_reviews}->{value} ne 'on')
      {
        INFO('Single project member found: ' . $lone_reviewer->name);
        set_new_reviewer($revision, $project, $lone_reviewer, $is_blocking, \@review_users);
        next;
      }
    }

    # If the member is one of the reviewers for a revision in the stack,
    # then use the same reviewer for this revision
    if (@stack_reviewers) {
      foreach my $member (@project_members) {
        next if none { $_->id == $member->id } @stack_reviewers;
        next if $member->phid eq $revision->author->phid;
        INFO('Found a previous stack reviewer: ' . $member->name);
        set_new_reviewer($revision, $project, $member, $is_blocking, \@review_users);
        next PROJECT;
      }
    }

    # Make sure that none of the individual group members are not already
    # set as a reviewer. If so, then remove the rotation group and go on
    # to next project. We do not want to call set_new_reviewer() since we
    # do not want this reviewer set to last reviewer in the DB.
    if (@review_users) {
      foreach my $member (@project_members) {
        next if none { $_->id == $member->id } @review_users;
        INFO('Member manually set as a reviewer so done: ' . $member->name);
        $revision->remove_reviewer($project->phid);
        $revision->add_subscriber($project->phid);
        next PROJECT;
      }
    }

    # Loop through all members and pick the next one in line after last selected
    foreach my $member (@project_members) {
      INFO('Considering candidate reviewer: ' . $member->name);

      # Here we look to see if they can see the bug, and they are not set to away
      # (not accepting reviews). If both are positive, we have found our reviewer
      # and exit the loop.
      if ($member->phid ne $revision->author->phid
        && $member->bugzilla_user->can_see_bug($revision->bug->id)
        && $member->bugzilla_user->settings->{block_reviews}->{value} ne 'on')
      {
        INFO('Promoting member to reviewer: ' . $member->name);
        set_new_reviewer($revision, $project, $member, $is_blocking, \@review_users);
        next PROJECT;
      }
    }

    # If we got to this point, we did not find a suitable reviewer so
    # we will leave a comment in the revision with explanation. First
    # we need to check to make sure we have not already added this comment.
    my $comments     = $revision->comments;
    my $project_name = $project->name;
    INFO("A reviewer was not found for $project_name.");
    if (none {$_->text =~ /REVIEWER ROTATION:.* $project_name/} @{$comments}) {
      INFO('Adding comment to revision because reviewer not found');
      $revision->add_comment(
        'REVIEWER ROTATION: An available rotation reviewer was not found from the group '
          . $project->name
          . ' for this revision.');
    }
    else {
      INFO('Comment already added previously. Skipping.');
    }
  }

  # Save changes to the revision and return.
  $revision->update;
}

sub set_new_reviewer {
  my ($revision, $project, $member, $is_blocking, $review_users) = @_;

  INFO('Setting new reviewer ' . $member->name);

  # Set the user as a reviewer on the revision.
  if ($is_blocking->{$project->phid}) {
    $revision->add_reviewer('blocking(' . $member->phid . ')');
  }
  else {
    $revision->add_reviewer($member->phid);
  }

  # Remove the review rotation group.
  INFO('Removing reviewer project');
  $revision->remove_reviewer($project->phid);

  # And add to subscriber list
  INFO('Adding reviewer project to subscriber list');
  $revision->add_subscriber($project->phid);

  # Store the data in the phab_reviewer_rotation table so they will be
  # next time.
  update_last_reviewer_phid($project, $member);

  # Add new reviewer to review users list in case they are also
  # a member of the next review rotation group.
  push @{$review_users}, $member;
}

sub rotate_reviewer_list {
  my ($project_members, $last_reviewer_phid) = @_;
  my @project_members = @{$project_members};

  return @project_members if !$last_reviewer_phid;

  # Find index of the last reviewer
  my ($index)
    = grep { $project_members[$_]->phid eq $last_reviewer_phid }
    0..$#project_members;

  # If the last reviewer is no longer a member of the group (e.g. they left
  # the project), treat it as if there is no previous reviewer and return the
  # list unrotated.
  return @project_members if !defined $index;

  # Rotate the list so the last reviewer is at the end, meaning they will
  # only be selected if no other eligible reviewer is available.
  my @rotated_members = (
    @project_members[$index + 1..$#project_members],
    @project_members[0..$index]
  );

  INFO(
    'Rotated project members ' . (join ', ', map { $_->name } @rotated_members));

  return @rotated_members;
}

sub find_last_reviewer_phid {
  my ($project) = @_;
  INFO('Retrieving last reviewer for project ' . $project->phid);
  return Bugzilla->dbh->selectrow_array(
    'SELECT user_phid FROM phab_reviewer_rotation WHERE project_phid = ?',
    undef, $project->phid);
}

sub update_last_reviewer_phid {
  my ($project, $reviewer) = @_;
  my $dbh = Bugzilla->dbh;

  INFO(
    'Updating last reviewer ' . $reviewer->name . ' for project ' . $project->name);

  $dbh->do('DELETE FROM phab_reviewer_rotation WHERE project_phid = ?',
    undef, $project->phid);
  $dbh->do(
    'INSERT INTO phab_reviewer_rotation (project_phid, user_phid) VALUES (?, ?)',
    undef, $project->phid, $reviewer->phid);
}

sub get_stack_reviewers {
  my ($revision, $is_blocking) = @_;
  my @stack_reviewers;

  INFO('Retrieving stack reviewers from all stack revisions');

  my $stack_data = $revision->stack_graph;

  foreach my $phid (@{$stack_data->{phids}}) {
    next if $phid eq $revision->phid;    # Skip this revision
    my $stack_revision
      = Bugzilla::Extension::PhabBugz::Revision->new_from_query({phids => [$phid]});
    next if !$stack_revision;
    foreach my $reviewer (@{$stack_revision->reviews}) {
      next if $reviewer->{is_project};
      push @stack_reviewers, $reviewer->{user};
      $is_blocking->{$reviewer->{user}->phid} = $reviewer->{is_blocking} ? 1 : 0;
    }
  }

  INFO(
    'Stack reviewers found: '
      . (
      @stack_reviewers ? (join ', ', map { $_->name } @stack_reviewers) : 'None'
      )
  );

  return @stack_reviewers;
}

sub get_review_rotation_projects {
  my ($revision, $is_blocking) = @_;
  my @review_projects;

  INFO('Retrieving review rotation projects');

  foreach my $reviewer (@{$revision->reviews || []}) {

    # Only interested in projects
    next if !$reviewer->{is_project};

    # Only interested in reviewer rotation groups
    next if $reviewer->{user}->name !~ /-reviewers?-rotation$/;

    push @review_projects, $reviewer->{user};
    $is_blocking->{$reviewer->{user}->phid} = $reviewer->{is_blocking} ? 1 : 0;
  }

  INFO(
    'Reviewer rotation projects found: '
      . (
      @review_projects ? (join ', ', map { $_->name } @review_projects) : 'None'
      )
  );

  return @review_projects;
}

sub get_review_users {
  my ($revision, $is_blocking) = @_;
  my @review_users;

  INFO('Retrieving review users (not projects)');

  foreach my $reviewer (@{$revision->reviews}) {

    # Only interested in users, not projects
    next if $reviewer->{is_project};

    push @review_users, $reviewer->{user};
    $is_blocking->{$reviewer->{user}->phid} = $reviewer->{is_blocking} ? 1 : 0;
  }

  INFO('Individual reviewers found: '
      . (@review_users ? (join ', ', map { $_->name } @review_users) : 'None'));

  return @review_users;
}

# 1981211 - If reviewer is #intermittent-reviewers and #taskgraph-reviewers do not allow other
# group reviewers as blocking. Instead move any other blocking reviewers to the subscriber list.
sub set_intermittent_reviewers {
  my ($revision) = @_;

  INFO('D' . $revision->id . ': Setting intermittent reviewers');

  # Load a fresh version of the revision with Heralds changes.
  $revision = Bugzilla::Extension::PhabBugz::Revision->new_from_query(
    {phids => [$revision->phid]});

  # Look up all blocking projects currently on the revision
  INFO('Retrieving blocking projects');

  my @blocking_projects;
  foreach my $reviewer (@{$revision->reviews || []}) {
    next if !$reviewer->{is_project} || !$reviewer->{is_blocking};
    push @blocking_projects, $reviewer->{user};
  }

  INFO('Blocking projects found: ' . (@blocking_projects ? (join ', ', map { $_->name } @blocking_projects) : 'None'));

  # Return unless the revision has both intermittent-reviewers and taskgraph-reviewers
  my $has_intermittent = any { $_->name eq 'intermittent-reviewers' } @blocking_projects;
  my $has_taskgraph    = any { $_->name eq 'taskgraph-reviewers' } @blocking_projects;
  if (!$has_intermittent || !$has_taskgraph) {
    INFO('Intermittent or taskgraph reviewers project not found. Returning.');
    return;
  }

  # Now we need to remove any blocking project that is not intermittent-reviewers and
  # taskgraph-reviewers project and move them to the subscribers list
  foreach my $project (@blocking_projects) {
    next if $project->name eq 'intermittent-reviewers' || $project->name eq 'taskgraph-reviewers';

    INFO('Removing blocking project ' . $project->name);
    $revision->remove_reviewer($project->phid);

    INFO('Adding blocking project ' . $project->name . ' to subscribers');
    $revision->add_subscriber($project->phid);
  }

  $revision->update;
}

1;
