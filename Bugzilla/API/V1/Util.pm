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

use Mojo::JSON qw(decode_json true false);

use Bugzilla;
use Bugzilla::Error;
use Bugzilla::Logging;
use Bugzilla::Util qw(datetime_from email_filter);
use Bugzilla::WebService::Constants;

use MIME::Base64 qw(encode_base64);
use Storable qw(dclone);
use Try::Tiny;
use Types::Standard -all;

use base qw(Exporter);

# Plain functions, imported by the API modules. The class methods below
# (type, updates_disabled, user_to_hash...) are called as
# Bugzilla::API::V1::Util->method instead.
our @EXPORT_OK = qw(
  extract_flags
  filter
  filter_wants
  merge_request_params
  params_to_objects
  set_rest_cors_headers
  strip_request_params
  translate
  validate
);

# Parameters that describe the request rather than the object it acts on:
# field selection, plus every spelling of a credential the legacy layer
# accepted and removed during login. Native controllers do not log in through
# that code, so nothing removes them from the merged params.
use constant REQUEST_PARAMS => qw(
  include_fields exclude_fields
  Bugzilla_api_key Bugzilla_api_token Bugzilla_login Bugzilla_password
  Bugzilla_restrictlogin Bugzilla_token
  api_key login password restrictlogin token
);

sub set_rest_cors_headers {
  my ($headers, $allowed_headers) = @_;
  if (!$allowed_headers) {
    my @default_headers
      = qw(accept authorization content-type origin user-agent x-requested-with);
    foreach my $header (sort keys %{API_AUTH_HEADERS()}) {
      $header =~ tr/A-Z_/a-z\-/;
      push @default_headers, $header;
    }
    $allowed_headers = \@default_headers;
  }

  $headers->header('Access-Control-Allow-Origin' => '*');
  $headers->header(
    'Access-Control-Allow-Headers' => join(', ', @$allowed_headers));
}

sub extract_flags {
  my ($flags, $bug, $attachment) = @_;
  my (@new_flags, @old_flags);

  my $flag_types    = $attachment ? $attachment->flag_types : $bug->flag_types;
  my $current_flags = $attachment ? $attachment->flags      : $bug->flags;

  # Copy the user provided $flags as we may call extract_flags more than
  # once when editing multiple bugs or attachments.
  my $flags_copy = dclone($flags);

  foreach my $flag (@$flags_copy) {
    my $id      = $flag->{id};
    my $type_id = $flag->{type_id};

    my $new  = delete $flag->{new};
    my $name = delete $flag->{name};

    if ($id) {
      my $flag_obj = grep($id == $_->id, @$current_flags);
      $flag_obj
        || ThrowUserError('object_does_not_exist',
        {class => 'Bugzilla::Flag', id => $id});
    }
    elsif ($type_id) {
      my $type_obj = grep($type_id == $_->id, @$flag_types);
      $type_obj
        || ThrowUserError('object_does_not_exist',
        {class => 'Bugzilla::FlagType', id => $type_id});
      if (!$new) {
        my @flag_matches = grep($type_id == $_->type->id, @$current_flags);
        @flag_matches > 1 && ThrowUserError('flag_not_unique', {value => $type_id});
        if (!@flag_matches) {
          delete $flag->{id};
        }
        else {
          delete $flag->{type_id};
          $flag->{id} = $flag_matches[0]->id;
        }
      }
    }
    elsif ($name) {
      my @type_matches = grep($name eq $_->name, @$flag_types);
      @type_matches > 1 && ThrowUserError('flag_type_not_unique', {value => $name});
      @type_matches
        || ThrowUserError('object_does_not_exist',
        {class => 'Bugzilla::FlagType', name => $name});
      if ($new) {
        delete $flag->{id};
        $flag->{type_id} = $type_matches[0]->id;
      }
      else {
        my @flag_matches = grep($name eq $_->type->name, @$current_flags);
        @flag_matches > 1 && ThrowUserError('flag_not_unique', {value => $name});
        if (@flag_matches) {
          $flag->{id} = $flag_matches[0]->id;
        }
        else {
          delete $flag->{id};
          $flag->{type_id} = $type_matches[0]->id;
        }
      }
    }

    if ($flag->{id}) {
      push(@old_flags, $flag);
    }
    else {
      push(@new_flags, $flag);
    }
  }

  return (\@old_flags, \@new_flags);
}

sub filter($$;$$) {
  my ($params, $hash, $types, $prefix) = @_;
  my %newhash = %$hash;

  foreach my $key (keys %$hash) {
    delete $newhash{$key} if !filter_wants($params, $key, $types, $prefix);
  }

  return \%newhash;
}

sub filter_wants($$;$$) {
  my ($params, $field, $types, $prefix) = @_;

  # Since this is operation is resource intensive, we will cache the results
  # This assumes that $params->{*_fields} doesn't change between calls
  my $cache = Bugzilla->request_cache->{filter_wants} ||= {};
  $field = "${prefix}.${field}" if $prefix;

  if (exists $cache->{$field}) {
    return $cache->{$field};
  }

  # Mimic old behavior if no types provided
  my %field_types
    = map { $_ => 1 } (ref $types ? @$types : ($types || 'default'));

  my %include = map { $_ => 1 } @{$params->{'include_fields'} || []};
  my %exclude = map { $_ => 1 } @{$params->{'exclude_fields'} || []};

  my %include_types;
  my %exclude_types;

  # Only return default fields if nothing is specified
  $include_types{default} = 1 if !%include;

  # Look for any field types requested
  foreach my $key (keys %include) {
    next if $key !~ /^_(.*)$/;
    $include_types{$1} = 1;
    delete $include{$key};
  }
  foreach my $key (keys %exclude) {
    next if $key !~ /^_(.*)$/;
    $exclude_types{$1} = 1;
    delete $exclude{$key};
  }

  # Explicit inclusion/exclusion
  return $cache->{$field} = 0 if $exclude{$field};
  return $cache->{$field} = 1 if $include{$field};

  # If the user has asked to include all or exclude all
  return $cache->{$field} = 0 if $exclude_types{'all'};
  return $cache->{$field} = 1 if $include_types{'all'};

  # If the user has not asked for any fields specifically or if the user has asked
  # for one or more of the field's types (and not excluded them)
  foreach my $type (keys %field_types) {
    return $cache->{$field} = 0 if $exclude_types{$type};
    return $cache->{$field} = 1 if $include_types{$type};
  }

  my $wants = 0;
  if ($prefix) {

    # Include the field if the parent is include (and this one is not excluded)
    $wants = 1 if $include{$prefix};
  }
  else {
    # We want to include this if one of the sub keys is included
    my $key = $field . '.';
    my $len = length($key);
    $wants = 1 if grep { substr($_, 0, $len) eq $key } keys %include;
  }

  return $cache->{$field} = $wants;
}

sub validate {
  my ($self, $params, @keys) = @_;
  my $cache_key = join('|', (caller(1))[3], sort @keys);

  # Type->of() is the same as Type[], used here because it is easier
  # to chain with plus_coercions.
  state $array_of_nonrefs
    = ArrayRef->of(Maybe [Value])->plus_coercions(Maybe [Value], q{ [ $_ ] },);
  state $type_cache = {};
  my $params_type = $type_cache->{$cache_key} //= do {
    my %fields = map { $_ => Optional [$array_of_nonrefs] } @keys;
    Maybe [Dict [%fields, slurpy Any]];
  };

  # If $params is defined but not a reference, then we weren't
  # sent any parameters at all, and we're getting @keys where
  # $params should be.
  return ($self, undef) if (defined $params and !ref $params);

  # If @keys is not empty then we convert any named
  # parameters that have scalar values to arrayrefs
  # that match.
  $params = $params_type->coerce($params);
  if (my $type_error = $params_type->validate($params)) {
    WARN("validate() found type error: $type_error");
    ThrowUserError('invalid_params', {type_error => $type_error}) if $type_error;
  }

  return ($self, $params);
}

sub translate {
  my ($params, $mapped) = @_;
  my %changes;
  while (my ($key, $value) = each(%$params)) {
    my $new_field = $mapped->{$key} || $key;
    $changes{$new_field} = $value;
  }
  return \%changes;
}

sub params_to_objects {
  my ($params, $class) = @_;
  my (@objects, @objects_by_ids);

  @objects = map { $class->check($_) } @{$params->{names}} if $params->{names};

  @objects_by_ids = map { $class->check({id => $_}) } @{$params->{ids}}
    if $params->{ids};

  push(@objects, @objects_by_ids);
  my %seen;
  @objects = grep { !$seen{$_->id}++ } @objects;
  return \@objects;
}

sub merge_request_params {
  my ($c, $list_params) = @_;

  # $c->req->params already covers the query string plus, for POST/PUT, an
  # application/x-www-form-urlencoded or multipart body. Layer a JSON body
  # underneath that, so params work from either the query string or a JSON
  # request body. Query-string/form-body values win on a key collision,
  # matching the legacy REST layer (see fix_credentials/_retrieve_json_params
  # in Bugzilla::WebService::Server::REST) and the documented behavior in
  # docs/en/md/api/core/v1/general.md.
  #
  # A param's type must not depend on how many times it was sent: ->to_hash
  # returns a scalar for one occurrence and an arrayref for two. Callers
  # therefore declare which params are lists; those always come back as
  # arrayrefs, everything else always as a scalar.
  my %is_list = map { $_ => 1 } @{$list_params || []};
  my $params  = {};
  for my $name (@{$c->req->params->names}) {
    $params->{$name}
      = $is_list{$name} ? $c->req->every_param($name) : $c->req->param($name);
  }

  # Only decode a body that wasn't already parsed as form params, otherwise a
  # form-urlencoded or multipart request would be rejected as malformed JSON.
  # The legacy REST layer gets this for free: CGI.pm only populates
  # POSTDATA/PUTDATA for non-form content types.
  # Read the body once: for a file-backed request asset each ->body call
  # re-slurps it from disk.
  my $body = $c->req->body;
  if (length $body && !@{$c->req->body_params->names}) {
    my $body_params;
    my $error;
    try { $body_params = decode_json($body); }
    catch { $error = 'rest_malformed_json'; };
    return (undef, $error) if $error;
    $params = {%$body_params, %$params} if ref $body_params eq 'HASH';
  }

  return ($params, undef);
}

sub strip_request_params {
  my ($params, @also) = @_;
  my %values = %$params;
  delete @values{REQUEST_PARAMS, @also};
  return \%values;
}

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

__END__

=head1 NAME

Bugzilla::API::V1::Util - Helpers shared by the native API modules.

=head1 FUNCTIONS

=head2 filter

This helps implement the C<include_fields> and C<exclude_fields> arguments
of WebService methods. Given a hash (the second argument to this subroutine),
this will remove any keys that are I<not> in C<include_fields> and then remove
any keys that I<are> in C<exclude_fields>.

An optional third option can be passed that prefixes the field name to allow
filtering of data two or more levels deep.

For example, if you want to filter out the C<id> key/value in components returned
by Product.get, you would use the value C<component.id> in your C<exclude_fields>
list.

=head2 filter_wants

Returns C<1> if a filter would preserve the specified field when passing
a hash to L</filter>, C<0> otherwise.

=head2 validate

This helps in the validation of parameters passed into the WebService
methods. Currently it converts listed parameters into an array reference
if the client only passed a single scalar value. It modifies the parameters
hash in place so other parameters should be unaltered.

=head2 params_to_objects

Creates objects of the type passed in as the second parameter, using the
parameters passed to a WebService method (the first parameter to this function).
Helps make life simpler for WebService methods that internally create objects
via both "ids" and "names" fields. Also de-duplicates objects that were loaded
by both "ids" and "names". Returns an arrayref of objects.

=head2 merge_request_params

Takes a Mojolicious controller and returns a two-element list
C<($params, $error)>, merging its query string/form-body params with a
decoded JSON request body, if any. Query-string/form-body values win on a
key collision. For use by native Mojo REST controllers that need to accept
parameters from either the query string or a JSON body on non-GET
requests.

An optional second argument is an arrayref of parameter names that are
lists, e.g. C<merge_request_params($c, ['ids'])>. Those are always returned
as arrayrefs, however many times they appear in the request; every other
parameter is always returned as a scalar. Declaring them is required because
a parameter's type must not depend on the number of occurrences sent.

If the request has a non-empty body that fails to decode as JSON, C<$params>
is C<undef> and C<$error> is set to C<rest_malformed_json>; callers should
pass it to C<user_error>. Otherwise C<$error> is C<undef>.

=head2 strip_request_params

Takes the hashref returned by L</merge_request_params> and returns a copy
without the C<REQUEST_PARAMS> keys (C<include_fields>, C<exclude_fields> and
the authentication parameters), plus any further names passed after it, e.g.
C<strip_request_params($params, qw(ids names))>. For controllers that hand
what is left to C<set_all>, which raises C<unknown_method> on any key that is
not a field of the object.

=head2 extract_flags

Subroutine that takes a list of hashes that are potential flag changes for
both bugs and attachments. Then breaks the list down into two separate lists
based on if the change is to add a new flag or to update an existing flag.
