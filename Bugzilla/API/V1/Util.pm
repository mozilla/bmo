# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Util;

use 5.10.1;
use strict;
use warnings;

use Mojo::JSON qw(true false);

use Bugzilla;
use Bugzilla::Util qw(datetime_from email_filter);
use Bugzilla::WebService::Constants;
use Bugzilla::WebService::Util qw(filter filter_wants);

use MIME::Base64 qw(encode_base64);

# Same output as type() on the legacy JSON-RPC/REST server.
sub type {
  my ($class, $type, $value) = @_;

  # This is the only type that does something special with undef.
  return $value ? true : false if $type eq 'boolean';

  return undef        if !defined $value;
  return int($value)  if $type eq 'int';
  return 0.0 + $value if $type eq 'double';
  return "$value"     if $type eq 'string';
  return email_filter($value)
    if $type eq 'email' && Bugzilla->params->{webservice_email_filter};

  # Always UTC, with the timezone specifier.
  return $value ? datetime_from($value, 'UTC')->iso8601() . 'Z' : ''
    if $type eq 'dateTime';

  if ($type eq 'base64') {
    utf8::encode($value) if utf8::is_utf8($value);
    return encode_base64($value, '');
  }

  return $value;
}

# The legacy REST server answered a bug change made while bug updates are
# disabled with the HTML "updates disabled" page, as ThrowErrorPage() only
# returns an error object in JSON-RPC mode. Render the JSON error an API client
# can handle, with the generic code user_error() uses for an error that has no
# code of its own.
sub updates_disabled {
  my ($class, $c) = @_;
  return $c->render(
    json => {
      error         => 1,
      code          => ERROR_UNKNOWN_TRANSIENT,
      message       => 'Bug updates are currently disabled.',
      documentation => Bugzilla->localconfig->urlbase . 'docs/en/md/api/index.md',
    },
    status => REST_STATUS_CODE_MAP()->{_default}
  );
}

# The hashes below are shared by the bug, attachment and comment API modules.

sub user_to_hash {
  my ($class, $user, $filters, $types, $prefix) = @_;
  return filter $filters,
    {
    id        => $class->type('int',    $user->id),
    real_name => $class->type('string', $user->name),
    nick      => $class->type('string', $user->nick),
    name      => $class->type('email',  $user->login),
    email     => $class->type('email',  $user->email),
    },
    $types, $prefix;
}

sub flag_to_hash {
  my ($class, $flag) = @_;

  my $item = {
    id                => $class->type('int',      $flag->id),
    name              => $class->type('string',   $flag->name),
    type_id           => $class->type('int',      $flag->type_id),
    creation_date     => $class->type('dateTime', $flag->creation_date),
    modification_date => $class->type('dateTime', $flag->modification_date),
    status            => $class->type('string',   $flag->status)
  };

  foreach my $field (qw(setter requestee)) {
    my $field_id = $field . "_id";
    $item->{$field} = $class->type('email', $flag->$field->login)
      if $flag->$field_id;
  }

  return $item;
}

sub attachment_to_hash {
  my ($class, $attach, $filters, $types, $prefix) = @_;

  my $item = filter $filters,
    {
    creation_time    => $class->type('dateTime', $attach->attached),
    last_change_time => $class->type('dateTime', $attach->modification_time),
    id               => $class->type('int',      $attach->id),
    bug_id           => $class->type('int',      $attach->bug_id),
    file_name        => $class->type('string',   $attach->filename),
    summary          => $class->type('string',   $attach->description),
    description      => $class->type('string',   $attach->description),
    content_type     => $class->type('string',   $attach->contenttype),
    is_private       => $class->type('int',      $attach->isprivate),
    is_obsolete      => $class->type('int',      $attach->isobsolete),
    is_patch         => $class->type('int',      $attach->ispatch),
    },
    $types, $prefix;

  # creator/attacher require an extra lookup, so we only send them if
  # the filter wants them.
  foreach my $field (qw(creator attacher)) {
    if (filter_wants $filters, $field, $types, $prefix) {
      $item->{$field} = $class->type('email', $attach->attacher->login);
    }
  }

  if (filter_wants $filters, 'creator', $types, $prefix) {
    $item->{'creator_detail'}
      = $class->user_to_hash($attach->attacher, $filters, undef, 'creator');
  }

  if (filter_wants $filters, 'data', $types, $prefix) {
    $item->{'data'} = $class->type('base64', $attach->data);
  }

  if (filter_wants $filters, 'size', $types, $prefix) {
    $item->{'size'} = $class->type('int', $attach->datasize);
  }

  if (filter_wants $filters, 'flags', $types, $prefix) {
    $item->{'flags'} = [map { $class->flag_to_hash($_) } @{$attach->flags}];
  }

  return $item;
}

sub comment_to_hash {
  my ($class, $comment, $filters, $types, $prefix) = @_;
  my $attach_id = $comment->is_about_attachment ? $comment->extra_data : undef;

  my $comment_hash = {
    id            => $class->type('int',      $comment->id),
    bug_id        => $class->type('int',      $comment->bug_id),
    creator       => $class->type('email',    $comment->author->login),
    author        => $class->type('email',    $comment->author->login),
    time          => $class->type('dateTime', $comment->creation_ts),
    creation_time => $class->type('dateTime', $comment->creation_ts),
    is_private    => $class->type('boolean',  $comment->is_private),
    text          => $class->type('string',   $comment->body_full),
    raw_text      => $class->type('string',   $comment->body),
    attachment_id => $class->type('int',      $attach_id),
    count         => $class->type('int',      $comment->count),
  };

  # Only set by preload_comment_edit_info when the user may edit others' comments
  if (my $edit_info = $comment->{edit_info}) {
    $comment_hash->{edit_count} = $class->type('int', $edit_info->{edit_count});
    $comment_hash->{last_change_time}
      = $class->type('dateTime', $edit_info->{last_change_time});
  }

  if (Bugzilla->params->{use_comment_reactions}) {
    $comment_hash->{reactions} = {};

    foreach my $key (keys %{$comment->reactions}) {
      $comment_hash->{reactions}->{$key}
        = $class->type('int', $comment->reactions->{$key});
    }
  }

  # Don't load comment tags unless enabled
  if (Bugzilla->params->{'comment_taggers_group'}) {
    $comment_hash->{tags} = [map { $class->type('string', $_) } @{$comment->tags}];
    $comment_hash->{collapsed} = $class->type('boolean', $comment->collapsed);
  }

  return filter($filters, $comment_hash, $types, $prefix);
}

# Fetches the revision metadata (number of edits and the timestamp of the most
# recent edit) for a set of comments using a single query, and stashes it on
# each comment object for comment_to_hash.
#
# The data is only exposed to users who are allowed to edit other people's
# comments; everyone else gets no edit_count/last_change_time keys at all.
# Revisions hidden by an edit-comments admin are only counted for admins.
#
# Comments that were already preloaded are skipped, so callers that batch every
# comment of a request up front turn later calls into no-ops.
sub preload_comment_edit_info {
  my ($class, $comments) = @_;
  my $user = Bugzilla->user;

  # can_edit_comments is injected by the EditComments extension; without it
  # there is no longdescs_activity table to query.
  return unless $user->can('can_edit_comments') && $user->can_edit_comments;

  my @todo = grep { !exists $_->{edit_info} } @$comments;
  return unless @todo;

  my $dbh = Bugzilla->dbh;
  my @ids = map { $_->id } @todo;

  # Admins can see hidden revisions, so they are counted for them only.
  my $hidden_clause = $user->is_edit_comments_admin ? '' : 'AND is_hidden = 0';

  my $rows = $dbh->selectall_hashref(
    'SELECT comment_id, COUNT(*) AS edit_count,
            MAX(change_when) AS last_change_time
       FROM longdescs_activity
      WHERE ' . $dbh->sql_in('comment_id', \@ids) . " $hidden_clause
   GROUP BY comment_id", 'comment_id'
  );

  foreach my $comment (@todo) {
    $comment->{edit_info}
      = $rows->{$comment->id} || {edit_count => 0, last_change_time => undef};
  }
}

# Comments that Bugzilla::Comment::collapsed flags (tagged with one of the
# 'collapsed_comment_tags' tags, or authored by treeherder) are hidden behind a
# click in the web UI, so they are left out of the API response too unless the
# caller asks for them with include_fields=_collapsed_comments. Like the other
# underscore-prefixed include_fields values, it does not imply _default, so
# callers that want the usual fields as well need
# include_fields=_default,_collapsed_comments.
sub wants_collapsed_comments {
  my ($class, $params) = @_;
  return grep { $_ eq '_collapsed_comments' } @{$params->{include_fields} || []};
}

# include_fields and exclude_fields can be lists, comma or space separated, or
# both: turn them into flat lists of field names.
sub split_include_exclude {
  my ($class, $params) = @_;
  for my $name (qw(include_fields exclude_fields)) {
    next if !exists $params->{$name};
    $params->{$name} = [$params->{$name}] if !ref $params->{$name};
    $params->{$name} = [map { split(/[\s,]+/) } @{$params->{$name}}];
  }
}

1;
