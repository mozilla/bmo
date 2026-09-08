# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Github;
use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Attachment;
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::Milestone;
use Bugzilla::User;
use Bugzilla::Util qw(fetch_product_versions);

use Bugzilla::Extension::TrackingFlags::Flag;
use Bugzilla::Extension::TrackingFlags::Flag::Bug;

use Digest::SHA qw(hmac_sha256_hex);
use JSON::Validator::Joi qw(joi);
use Mojo::Util  qw(secure_compare);

use constant BUG_RE => qr/\b[Bb]ug(?:[ -]|: )(\d+)\b/;

sub setup_routes {
  my ($class, $r) = @_;
  $r->post('/github/pull_request')->to('V1::Github#pull_request');
  $r->post('/github/push_comment')->to('V1::Github#push_comment');
}

sub pull_request {
  my ($self) = @_;
  my $template = Bugzilla->template;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  # Return early if linking is not allowed
  return $self->code_error('github_pr_linking_disabled')
    if !Bugzilla->params->{github_pr_linking_enabled};

  # Return early if not a pull_request or ping event
  my $event = $self->req->headers->header('X-GitHub-Event');
  if (!$event || ($event ne 'pull_request' && $event ne 'ping')) {
    return $self->code_error('github_pr_not_pull_request');
  }

  # Verify that signature is correct based on shared secret
  if (!$self->_verify_signature) {
    return $self->code_error('github_mismatch_signatures');
  }

  # If event is a ping and we passed the signature check
  # then return success
  if ($event eq 'ping') {
    return $self->render(json => {error => 0});
  }

  # Validate JSON input
  my $payload = $self->req->json;
  my @errors  = joi->object->props(
    action       => joi->string->required,
    pull_request => joi->required->object->props({
      html_url => joi->string->required,
      title    => joi->string->required,
      number   => joi->integer->required,
    }),
    repository =>
      joi->required->object->props({full_name => joi->string->required,})
  )->validate($payload);
  return $self->user_error('api_input_schema_error', {errors => \@errors})
    if @errors;

  # We are only interested in new pull request events
  # and not changes to existing ones (non-fatal).
  my $message;
  if ($payload->{action} ne 'opened') {
    $template->process('global/code-error.html.tmpl',
      {error => 'github_pr_invalid_event'}, \$message)
      || die $template->error();
    return $self->render(json => {error => 1, message => $message});
  }

  my $html_url   = $payload->{pull_request}->{html_url};
  my $title      = $payload->{pull_request}->{title};
  my $pr_number  = $payload->{pull_request}->{number};
  my $repository = $payload->{repository}->{full_name};
  (my $repo_filename = $repository) =~ s|/|_|g;

  # Find bug ID in the title and see if bug exists and client
  # can see it (non-fatal).
  my ($bug_id) = $title =~ BUG_RE;
  my $bug = Bugzilla::Bug->new($bug_id);
  if ($bug->{error} || !Bugzilla->user->can_see_bug($bug->id)) {
    $template->process('global/code-error.html.tmpl',
      {error => 'github_pr_bug_not_found'}, \$message)
      || die $template->error();
    return $self->render(json => {error => 1, message => $message});
  }

  # Create new attachment using pull request URL as attachment content.
  # This path must be serialized per bug because concurrent webhook deliveries
  # can otherwise race between duplicate-check and insert.
  my $auto_user = Bugzilla::User->check({name => 'github-automation@bmo.tld'});
  $auto_user->{groups}       = [Bugzilla::Group->get_all];
  $auto_user->{bless_groups} = [Bugzilla::Group->get_all];
  Bugzilla->set_user($auto_user);

  my $dbh = Bugzilla->dbh;
  my $pr_lock_name = _acquire_pr_lock($dbh, $repository, $pr_number);
  if ($dbh->isa('Bugzilla::DB::Mysql') && !$pr_lock_name) {
    return $self->render(
      json => {
        error   => 1,
        message => 'Unable to acquire a lock for this pull request. Please retry.'
      }
    );
  }

  my ($attachment, $duplicate);
  eval {
    $dbh->bz_start_transaction;

    # Lock all potentially-affected bugs in sorted order before we read/write
    # attachments. This avoids deadlocks when two webhook deliveries move
    # different PR attachments between the same pair of bugs in opposite
    # directions.
    my $candidate_bug_ids = $dbh->selectcol_arrayref(
      'SELECT DISTINCT bug_id
         FROM attachments
        WHERE mimetype = ?
          AND filename = ?
          AND NOT isobsolete',
      undef,
      'text/x-github-pull-request',
      "github-$repo_filename-$pr_number-url.txt"
    );

    my %bug_ids_to_lock = map { $_ => 1 } @{$candidate_bug_ids // []};
    $bug_ids_to_lock{$bug->id} = 1;
    my @lock_bug_ids = sort { $a <=> $b } keys %bug_ids_to_lock;
    my $lock_placeholders = join(', ', ('?') x @lock_bug_ids);

    $dbh->selectcol_arrayref(
      "SELECT bug_id
         FROM bugs
        WHERE bug_id IN ($lock_placeholders)
        ORDER BY bug_id
        FOR UPDATE",
      undef,
      @lock_bug_ids
    );

    my $existing_attachments = Bugzilla::Attachment->match({
      bug_id   => $bug->id,
      mimetype => 'text/x-github-pull-request',
    });

    foreach my $existing_attachment (@$existing_attachments) {
      next if $existing_attachment->data ne $html_url;
      $template->process('global/code-error.html.tmpl',
        {error => 'github_pr_attachment_exists'}, \$message)
        || die $template->error();
      $duplicate = 1;
      last;
    }

    if ($duplicate) {
      $dbh->bz_commit_transaction;
      1;
    }
    else {

      my $timestamp = $dbh->selectrow_array("SELECT NOW()");

      $attachment = Bugzilla::Attachment->create({
        bug         => $bug,
        creation_ts => $timestamp,
        data        => $html_url,
        description => "[$repository] $title (#$pr_number)",
        filename    => "github-$repo_filename-$pr_number-url.txt",
        ispatch     => 0,
        isprivate   => 0,
        mimetype    => 'text/x-github-pull-request',
      });

      # Insert a comment about the new attachment into the database.
      $bug->add_comment(
        '',
        {
          type        => CMT_ATTACHMENT_CREATED,
          extra_data  => $attachment->id,
          is_markdown => (Bugzilla->params->{use_markdown} ? 1 : 0)
        }
      );
      $bug->update($timestamp);

      # Fixup attachments with same github pull request but on different bugs
      my %other_bugs;
      my $other_attachments = Bugzilla::Attachment->match({
        mimetype => 'text/x-github-pull-request',
        filename => "github-$repo_filename-$pr_number-url.txt",
        WHERE    => {'bug_id != ? AND NOT isobsolete' => $bug->id}
      });
      foreach my $attachment (@$other_attachments) {

        # data doesn't match this URL, skip it
        next if $attachment->data ne $html_url;

        $other_bugs{$attachment->bug_id}++;
        my $moved_comment
          = "GitHub pull request attachment was moved to bug "
          . $bug->id
          . ". Setting attachment "
          . $attachment->id
          . " to obsolete.";
        $attachment->set_is_obsolete(1);
        $attachment->bug->add_comment(
          $moved_comment,
          {
            type        => CMT_ATTACHMENT_UPDATED,
            extra_data  => $attachment->id,
            is_markdown => (Bugzilla->params->{use_markdown} ? 1 : 0)
          }
        );
        $attachment->bug->update($timestamp);
        $attachment->update($timestamp);
      }

      $dbh->bz_commit_transaction;
      1;
    }
  } or do {
    my $error = $@;
    $dbh->bz_rollback_transaction;
    _release_pr_lock($dbh, $pr_lock_name);
    die $error;
  };

  _release_pr_lock($dbh, $pr_lock_name);

  if ($duplicate) {
    return $self->render(json => {error => 1, message => $message});
  }

  # Return new attachment id when successful
  return $self->render(json => {error => 0, id => $attachment->id});
}

sub _acquire_pr_lock {
  my ($dbh, $repository, $pr_number) = @_;

  # Named advisory locks are MySQL-specific. bmo uses MySQL in production.
  return undef if !$dbh->isa('Bugzilla::DB::Mysql');

  my $lock_name
    = 'github-pr:'
    . substr(hmac_sha256_hex("$repository#$pr_number", 'github_pr_lock'), 0, 54);

  my ($locked) = $dbh->selectrow_array(
    'SELECT GET_LOCK(?, ?)',
    undef,
    $lock_name,
    30
  );

  return $locked ? $lock_name : undef;
}

sub _release_pr_lock {
  my ($dbh, $lock_name) = @_;
  return if !$lock_name;
  $dbh->selectrow_array('SELECT RELEASE_LOCK(?)', undef, $lock_name);
}

sub push_comment {
  my ($self) = @_;
  my $template = Bugzilla->template;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  # Return early if push commenting is not allowed
  return $self->code_error('github_push_comment_disabled')
    if !Bugzilla->params->{github_push_comment_enabled};

  # Return early if not a push or ping event
  my $event = $self->req->headers->header('X-GitHub-Event');
  if (!$event || ($event ne 'push' && $event ne 'ping')) {
    return $self->code_error('github_push_comment_not_push');
  }

  # Verify that signature is correct based on shared secret
  if (!$self->_verify_signature) {
    return $self->code_error('github_mismatch_signatures');
  }

  # If event is a ping and we passed the signature check
  # then return success
  if ($event eq 'ping') {
    return $self->render(json => {error => 0});
  }

  # Validate JSON input
  my $payload = $self->req->json;
  my @errors  = joi->object->props(
    ref => joi->string->required,
    repository => joi->required->object->props({
      full_name      => joi->string->required,
      default_branch => joi->string->required,
    }),
    commits => joi->array->items(joi->object->props({
      message => joi->string->required,
      url     => joi->string->required,
      author  => joi->required->object->props({
        name     => joi->string->required,
        username => joi->string,
      }),
    })),
  )->validate($payload);
  return $self->user_error('api_input_schema_error', {errors => \@errors})
    if @errors;

  my $ref            = $payload->{ref};
  my $repository     = $payload->{repository}->{full_name};
  my $default_branch = $payload->{repository}->{default_branch};
  my $commits        = $payload->{commits};
  my ($branch)       = $ref =~ /refs\/heads\/(.*)$/;

  # Return success early if there are no commits
  # or the branch is not one we are interested in.
  if (!@{$commits} || $branch !~ /^(?:$default_branch|releases_v\d+)$/) {
    return $self->render(json => {error => 0});
  }

  # Keep a list of bug ids that need to have comments added.
  # We also use this for sending email later.
  # Use a hash so we don't have duplicates. If multiple commits
  # reference the same bug ID, then only one comment will be added
  # with the text combined.
  # When the comment is created, we will store the comment id to
  # return to the caller.
  my %update_bugs;

  # Create a separate comment for each commit
  foreach my $commit (@{$commits}) {
    my $message = $commit->{message};
    my $url     = $commit->{url};

    # author.username is not always available but author.name should be.
    # We will format the author portion of the comment differently
    # depending on which values we get.
    my $author;
    if ($commit->{author}->{username}) {
      $author = 'https://github.com/' . $commit->{author}->{username};
    }
    else {
      $author = $commit->{author}->{name};
    }

    if (!$url || !$message) {
      return $self->code_error('github_pr_invalid_json');
    }

    # Find bug ID in the title and see if bug exists
    my ($bug_id) = $message =~ BUG_RE;
    next if !$bug_id;

    # Only include the first line of the commit message
    $message = (split /\n/, $message)[0];

    my $comment_text = "Authored by $author\n$url\n[$branch] $message";

    $update_bugs{$bug_id} ||= [];
    push @{$update_bugs{$bug_id}}, {text => $comment_text};
  }

  # If no bugs were found, then we return an error
  if (!keys %update_bugs) {
    return $self->code_error('github_push_comment_bug_not_found');
  }

  # Set current user to automation so we can add comments to private bugs
  my $auto_user = Bugzilla::User->check({name => 'github-automation@bmo.tld'});
  $auto_user->{groups}       = [Bugzilla::Group->get_all];
  $auto_user->{bless_groups} = [Bugzilla::Group->get_all];
  Bugzilla->set_user($auto_user);

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction;

  # Actually create the comments in this loop
  foreach my $bug_id (keys %update_bugs) {
    my $bug = Bugzilla::Bug->new({id => $bug_id, cache => 1});
    # Skip bug silently if it does not exist
    next if $bug->{error};

    # Create a single comment if one or more commits reference the same bug
    my $comment_text;
    foreach my $comment (@{$update_bugs{$bug_id}}) {
      $comment_text .= $comment->{text} . "\n\n";
    }

    # Set all parameters
    my $set_all = {
      comment => {
        body => $comment_text
      }
    };

    # If the bug does not have the keyword 'leave-open', we close the bug as RESOLVED/FIXED.
    if (!$bug->has_keyword('leave-open')
      && $bug->status ne 'RESOLVED'
      && $bug->status ne 'VERIFIED')
    {
      # Set the bugs status to RESOLVED/FIXED
      $set_all->{bug_status} = 'RESOLVED';
      $set_all->{resolution} = 'FIXED';

      # Update the qe-verify flag if not set and the bug was closed.
      # Do not set the flag if the no-qe-verify parameter is true.
      if (!$self->param('no-qe-verify')) {
        my $found_flag;
        foreach my $flag (@{$bug->flags}) {

          # Ignore for all flags except `qe-verify`.
          next if $flag->name ne 'qe-verify';
          $found_flag = 1;
          last;
        }

        if (!$found_flag) {
          my $qe_flag = Bugzilla::FlagType->new({name => 'qe-verify'});
          if ($qe_flag) {
            $bug->set_flags(
              [],
              [{
                flagtype => $qe_flag,
                setter   => Bugzilla->user,
                status   => '+',
                type_id  => $qe_flag->id,
              }]
            );
          }
        }
      }

      # Currently tailored for mozilla-mobile/firefox-android only
      if ($repository eq 'mozilla-mobile/firefox-android') {

        # Update the milestone to the nightly branch if default branch
        if ($ref =~ /refs\/heads\/$default_branch/) {
          $self->_set_nightly_milestone($bug, $set_all);
        }

        # Update the status flag to 'fixed' if one exists for the current branch
        $self->_set_status_flag($bug, $set_all, $branch);
      }
    }

    $bug->set_all($set_all);
    $bug->update();

    my $comments       = $bug->comments({order => 'newest_to_oldest'});
    my $new_comment_id = $comments->[0]->id;

    $dbh->bz_commit_transaction;

    $update_bugs{$bug_id} = {id => $new_comment_id, text => $comment_text};

    # Send mail
    Bugzilla::BugMail::Send($bug_id, {changer => Bugzilla->user});
  }

  # Return comment id when successful
  return $self->render(json => {error => 0, bugs => \%update_bugs});
}

sub _verify_signature {
  my ($self)             = @_;
  my $payload            = $self->req->body;
  my $received_signature = $self->req->headers->header('X-Hub-Signature-256');

  return 0 if !$received_signature;

  # Fast path: check legacy shared secret first during migration period.
  # Operators should migrate to per-bot API keys and clear this parameter.
  my $legacy_secret = Bugzilla->params->{github_pr_signature_secret};
  if ($legacy_secret) {
    my $expected = 'sha256=' . hmac_sha256_hex($payload, $legacy_secret);
    return 1 if secure_compare($expected, $received_signature);
  }

  # Fetch all non-revoked, non-sticky API keys for users in the github-webhook-bot group.
  # Each bot account uses its own Bugzilla API key as the GitHub webhook secret,
  # so individual keys can be revoked without affecting other integrations.
  # Sticky keys are excluded because they are IP-bound and not appropriate for
  # webhook use from GitHub's IP ranges.
  my $dbh  = Bugzilla->dbh;
  my $keys = $dbh->selectall_arrayref(
    "SELECT uak.id, uak.api_key
       FROM user_api_keys uak
       INNER JOIN user_group_map ugm ON ugm.user_id = uak.user_id
       INNER JOIN " . $dbh->quote_identifier('groups') . " g ON g.id = ugm.group_id
      WHERE g.name = 'github-webhook-bot'
        AND uak.revoked = 0
        AND uak.sticky = 0
        AND ugm.isbless = 0
        AND ugm.grant_type = " . GRANT_DIRECT,
    {Slice => {}}
  );

  foreach my $key_row (@{$keys}) {
    my $expected = 'sha256=' . hmac_sha256_hex($payload, $key_row->{api_key});
    if (secure_compare($expected, $received_signature)) {
      # Track key usage so operators can see which key last authenticated a webhook request
      $dbh->do(
        "UPDATE user_api_keys SET last_used = LOCALTIMESTAMP(0), last_used_ip = ? WHERE id = ?",
        undef, $self->tx->remote_address, $key_row->{id}
      );
      return 1;
    }
  }

  return 0;
}

# If the ref matches a certain branch pattern for the repo we are interested
# in, then we also need to set the appropriate status flag to 'fixed'.
sub _set_status_flag {
  my ($self, $bug, $set_all, $branch) = @_;

  # In order to determine the appropriate status flag for the default
  # branch, we have to find out what the current *nightly* Firefox version is.
  # fetch_product_versions() calls an API endpoint maintained by rel-eng that
  # returns all of the current product versions so we can use that.
  my $version;
  if ($branch eq 'main' || $branch eq 'master') {
    my $versions = fetch_product_versions('firefox');
    return if (!$versions || !exists $versions->{FIREFOX_NIGHTLY});
    ($version) = split /[.]/, $versions->{FIREFOX_NIGHTLY};
  }
  # Release branches already have the version number embedded in the name.
  else {
    ($version) = $branch =~ /^releases_v(\d+)$/;
  }
  return if !$version;

  # Load the appropriate status flag.
  my $status_field = 'cf_status_firefox' . $version;
  my $flag = Bugzilla::Extension::TrackingFlags::Flag->new({name => $status_field});

  # Return if the flag doesn't exist for some reason or the value fixed is already set
  return if (!$flag || $bug->$status_field eq 'fixed');

  $set_all->{$status_field} = 'fixed';
}

# If the bug is being closed, then we also need to set the appropriate
# nightly milestone version.
sub _set_nightly_milestone {
  my ($self, $bug, $set_all) = @_;

  # In order to determine the appropriate status flag for the 'master/main'
  # branch, we have to find out what the current *nightly* Firefox version is.
  # fetch_product_versions() calls an API endpoint maintained by rel-eng that
  # returns all of the current product versions so we can use that.
  my $versions = fetch_product_versions('firefox');
  return if (!$versions || !exists $versions->{FIREFOX_NIGHTLY});
  my ($version) = split /[.]/, $versions->{FIREFOX_NIGHTLY};
  return if !$version;

  # Load the appropriate milestone.
  my $value = "$version Branch";
  my $milestone
    = Bugzilla::Milestone->new({product => $bug->product_obj, name => $value});
  return if !$milestone;

  # Update the milestone
  $set_all->{target_milestone} = $milestone->name;
}

1;
