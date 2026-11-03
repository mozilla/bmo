# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::BugAttachment;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use List::MoreUtils qw(uniq);
use MIME::Base64    qw(decode_base64);

use Bugzilla::API::V1::Util;
use Bugzilla::Attachment;
use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Flag;
use Bugzilla::Util qw(detaint_natural remote_ip trim);
use Bugzilla::WebService::Util qw(extract_flags merge_request_params
  strip_request_params translate validate);

use constant ATTACHMENT_MAPPED_SETTERS =>
  {file_name => 'filename', summary => 'description',};

use constant ATTACHMENT_MAPPED_RETURNS => {
  description => 'summary',
  ispatch     => 'is_patch',
  isprivate   => 'is_private',
  isobsolete  => 'is_obsolete',
  filename    => 'file_name',
  mimetype    => 'content_type',
};

sub setup_routes {
  my ($class, $r) = @_;
  my $routes
    = $r->under('/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  $routes->get('/bug/#id/attachment')->to('V1::BugAttachment#attachments');
  $routes->post('/bug/#id/attachment')->to('V1::BugAttachment#add_attachment');
  $routes->get('/bug/attachment/#attachment_id')
    ->to('V1::BugAttachment#attachments');
  $routes->put('/bug/attachment/#attachment_id')
    ->to('V1::BugAttachment#update_attachment');

  $routes->options('/bug/#id/attachment')
    ->to('V1::BugAttachment#options', allow => 'GET, POST');
  $routes->options('/bug/attachment/#attachment_id')
    ->to('V1::BugAttachment#options', allow => 'GET, PUT');
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

# GET /bug/<id>/attachment and /bug/attachment/<attachment_id>
sub attachments {
  my ($self) = @_;

  my $user = $self->bugzilla->login;

  my $params = {};
  for my $name (qw(ids attachment_ids include_fields exclude_fields)) {
    my $values = $self->every_param($name);
    $params->{$name} = $values if @$values;
  }
  Bugzilla::API::V1::Util->split_include_exclude($params);

  # As on the legacy REST server, an id in the path is added to the ones from
  # the query string.
  for my $pair (['id', 'ids'], ['attachment_id', 'attachment_ids']) {
    my ($stash, $key) = @$pair;
    next if !defined(my $id = $self->stash($stash));
    $params->{$key} = [uniq($id, @{$params->{$key} || []})];
  }

  Bugzilla->switch_to_shadow_db() unless $user->id;

  my $ids        = $params->{ids}            || [];
  my $attach_ids = $params->{attachment_ids} || [];

  unless ($user->id) {
    Bugzilla->check_rate_limit("get_attachments", remote_ip());
  }

  my %bugs;
  foreach my $bug_id (@$ids) {
    my $bug = Bugzilla::Bug->check($bug_id);
    $bugs{$bug->id} = [];
    foreach my $attach (@{$bug->attachments}) {
      push @{$bugs{$bug->id}},
        Bugzilla::API::V1::Util->attachment_to_hash($attach, $params);
    }
  }

  my %attachments;
  my @log_attachments;
  foreach my $attach (@{Bugzilla::Attachment->new_from_list($attach_ids)}) {
    Bugzilla::Bug->check($attach->bug_id);
    if ($attach->isprivate && !$user->is_insider) {
      return $self->user_error('auth_failure',
        {action => 'access', object => 'attachment', attach_id => $attach->id});
    }
    push @log_attachments, $attach;

    $attachments{$attach->id}
      = Bugzilla::API::V1::Util->attachment_to_hash($attach, $params);
  }

  if ($user->id) {
    foreach my $attachment (@log_attachments) {
      Bugzilla->log_user_request($attachment->bug_id, $attachment->id,
        "attachment-get");
    }
  }

  return $self->render(json => {bugs => \%bugs, attachments => \%attachments});
}

# POST /bug/<id>/attachment
sub add_attachment {
  my ($self) = @_;

  # BMO: Don't allow updating of bugs if disabled
  return Bugzilla::API::V1::Util->updates_disabled($self)
    if Bugzilla->params->{disable_bug_updates};

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $error) = $self->_request_params;
  return $self->user_error($error) if $error;

  defined $params->{data}
    || return $self->code_error('param_required', {param => 'data'});
  $params->{data} = decode_base64($params->{data});

  my $dbh = Bugzilla->dbh;

  my @bugs = map { Bugzilla::Bug->check($_) } @{$params->{ids}};
  foreach my $bug (@bugs) {
    $user->can_edit_product($bug->product_id)
      || return $self->user_error("product_edit_denied",
      {product => $bug->product});
  }

  my @created;
  $dbh->bz_start_transaction();
  my $timestamp = $dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');

  my $flags       = delete $params->{flags};
  my $comment     = delete $params->{comment};
  my $is_markdown = delete $params->{is_markdown};
  my $bug_flags   = delete $params->{bug_flags};

  $comment = $comment ? trim($comment) : '';

  # Default to the system use_markdown setting, matching attachment.cgi.
  if (!defined $is_markdown) {
    $is_markdown = Bugzilla->params->{use_markdown} ? 1 : 0;
  }

  foreach my $bug (@bugs) {
    my $attachment = Bugzilla::Attachment->create({
      bug         => $bug,
      creation_ts => $timestamp,
      data        => $params->{data},
      description => $params->{summary},
      filename    => $params->{file_name},
      mimetype    => $params->{content_type},
      ispatch     => $params->{is_patch},
      isprivate   => $params->{is_private},
    });

    if ($flags) {
      my ($old_flags, $new_flags) = extract_flags($flags, $bug, $attachment);
      $attachment->set_flags($old_flags, $new_flags);
    }

    $attachment->update($timestamp);

    # The comment has to be added even if it's empty
    $bug->add_comment(
      $comment,
      {
        isprivate   => $attachment->isprivate,
        type        => CMT_ATTACHMENT_CREATED,
        extra_data  => $attachment->id,
        is_markdown => ($is_markdown ? 1 : 0),
      }
    );

    if ($bug_flags) {
      my ($old_flags, $new_flags) = extract_flags($bug_flags, $bug);
      $bug->set_flags($old_flags, $new_flags);
    }

    push(@created, $attachment);
  }
  $_->bug->update($timestamp) foreach @created;
  $dbh->bz_commit_transaction();

  $_->send_changes() foreach @bugs;

  my %attachments
    = map { $_->id => Bugzilla::API::V1::Util->attachment_to_hash($_, $params) }
    @created;

  return $self->render(json => {attachments => \%attachments}, status => 201);
}

# PUT /bug/attachment/<attachment_id>
sub update_attachment {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $error) = $self->_request_params;
  return $self->user_error($error) if $error;

  my $dbh = Bugzilla->dbh;
  my $ids = delete $params->{ids};

  # Drop the request-level keys, which are not attachment fields, so that
  # set_all() still raises unknown_method on an unrecognized field.
  $params = translate(strip_request_params($params), ATTACHMENT_MAPPED_SETTERS);

  # Get all the attachments, after verifying that they exist and are editable
  my @attachments = ();
  my %bugs        = ();
  foreach my $id (@$ids) {
    detaint_natural($id)
      || return $self->code_error('param_must_be_numeric',
      {function => 'Bug.update_attachment', param => 'ids'});
    my $attachment = Bugzilla::Attachment->new($id)
      || return $self->user_error("invalid_attach_id", {attach_id => $id});
    my $bug = $attachment->bug;
    $attachment->_check_bug;

    push @attachments, $attachment;
    $bugs{$bug->id} = $bug;
  }

  my $flags       = delete $params->{flags};
  my $comment     = delete $params->{comment};
  my $is_markdown = delete $params->{is_markdown};
  my $bug_flags   = delete $params->{bug_flags};

  $comment = $comment ? trim($comment) : '';

  # Default to the system use_markdown setting, matching attachment.cgi.
  if (!defined $is_markdown) {
    $is_markdown = Bugzilla->params->{use_markdown} ? 1 : 0;
  }

  # Update the values
  foreach my $attachment (@attachments) {
    my ($update_flags, $new_flags)
      = $flags ? extract_flags($flags, $attachment->bug, $attachment) : ([], []);
    if ($attachment->validate_can_edit) {
      $attachment->set_all($params);
      $attachment->set_flags($update_flags, $new_flags) if $flags;
    }
    elsif (scalar @$update_flags && !scalar(@$new_flags) && !scalar keys %$params) {

      # Requestees can set flags targeted to them, even if they cannot
      # edit the attachment. Flag setters can edit their own flags too.
      my %flag_list = map { $_->{id} => $_ } @$update_flags;
      my $flag_objs = Bugzilla::Flag->new_from_list([keys %flag_list]);
      my @editable_flags;
      foreach my $flag_obj (@$flag_objs) {
        if ($flag_obj->setter_id == $user->id
          || ($flag_obj->requestee_id && $flag_obj->requestee_id == $user->id))
        {
          push(@editable_flags, $flag_list{$flag_obj->id});
        }
      }
      if (!scalar @editable_flags) {
        return $self->user_error("illegal_attachment_edit",
          {attach_id => $attachment->id});
      }
      $attachment->set_flags(\@editable_flags, []);
    }
    else {
      return $self->user_error("illegal_attachment_edit",
        {attach_id => $attachment->id});
    }
  }

  $dbh->bz_start_transaction();

  # Do the actual update and get information to return to user
  my @result;
  foreach my $attachment (@attachments) {
    my $changes = $attachment->update();
    my $bug     = $attachment->bug;

    if ($comment) {
      $bug->add_comment(
        $comment,
        {
          isprivate   => $attachment->isprivate,
          type        => CMT_ATTACHMENT_UPDATED,
          extra_data  => $attachment->id,
          is_markdown => ($is_markdown ? 1 : 0),
        }
      );
    }

    if ($bug_flags) {
      my ($old_flags, $new_flags) = extract_flags($bug_flags, $bug);
      $bug->set_flags($old_flags, $new_flags);
    }

    $changes = translate($changes, ATTACHMENT_MAPPED_RETURNS);

    my %hash = (
      id               => $self->type('int',      $attachment->id),
      last_change_time => $self->type('dateTime', $attachment->modification_time),
      changes          => {},
    );

    foreach my $field (keys %$changes) {
      my $change = $changes->{$field};

      # We normalize undef to an empty string, so that the API
      # stays consistent for things like Deadline that can become
      # empty.
      $hash{changes}->{$field} = {
        removed => $self->type('string', $change->[0] // ''),
        added   => $self->type('string', $change->[1] // '')
      };
    }

    push(@result, \%hash);
  }

  $dbh->bz_commit_transaction();

  # Email users about the change
  foreach my $bug (values %bugs) {
    $bug->update();
    $bug->send_changes();
  }

  # Return the information to the user
  return $self->render(json => {attachments => \@result});
}

# Parameters of a POST or PUT: the query string and the request body, as on
# the legacy REST server. The id in the path is only used when neither of
# them has "ids".
sub _request_params {
  my ($self) = @_;

  my ($params, $error)
    = merge_request_params($self, [qw(ids include_fields exclude_fields)]);
  return (undef, $error) if $error;

  # As legacy validate(@_, 'ids'): a single id becomes a list, and anything
  # but a list of plain values (e.g. a hash of conditions) is invalid_params.
  (undef, $params) = validate($self, $params, 'ids');
  $params->{ids} //= [$self->stash('id') // $self->stash('attachment_id')];
  Bugzilla::API::V1::Util->split_include_exclude($params);

  return ($params, undef);
}

1;
