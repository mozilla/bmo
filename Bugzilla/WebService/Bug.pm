# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::WebService::Bug;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::WebService);

use Bugzilla::Comment;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Logging;
use Bugzilla::WebService::Constants;
use Bugzilla::WebService::Util
  qw(extract_flags filter filter_wants validate translate);
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::Util qw(trim detaint_natural remote_ip);
use Bugzilla::Token qw(issue_hash_token);
use Bugzilla::Search;
use Bugzilla::Product;
use Bugzilla::Search::Quicksearch;

use List::Util qw(max);
use List::MoreUtils qw(uniq);
use Mojo::Util qw(dumper);
use Storable qw(dclone);
use Types::Standard -all;
use Type::Utils;

#############
# Constants #
#############

sub DATE_FIELDS {
  my $fields = {
    create   => [],
    history  => ['new_since'],
    search   => ['last_change_time', 'creation_time'],
    update   => []
  };

  # Add datetime custom fields. Date-only fields are left out so they are
  # passed through as YYYY-MM-DD, since converting them would append a time
  # component that _check_date_field rejects.
  foreach my $field (Bugzilla->active_custom_fields({skip_extensions => 1})) {
    next unless $field->type == FIELD_TYPE_DATETIME;
    push(@{$fields->{create}}, $field->name);
    push(@{$fields->{update}}, $field->name);
  }

  return $fields;
}

use constant READ_ONLY => qw(
  get
  history
  search
);

use constant PUBLIC_METHODS => qw(
  create
  get
  history
  possible_duplicates
  search
  update
  update_see_also
);

our %api_field_types = (
  %{{map { $_ => 'double' } Bugzilla::Bug::NUMERIC_COLUMNS()}},
  %{{map { $_ => 'dateTime' } Bugzilla::Bug::DATE_COLUMNS()}},
);

our %api_field_names = reverse %{Bugzilla::Bug::FIELD_MAP()};
# This doesn't normally belong in FIELD_MAP, but we do want to translate
# "bug_group" back into "groups".
$api_field_names{'bug_group'} = 'groups';

######################################################
# Add aliases here for old method name compatibility #
######################################################

BEGIN {
  # In 3.0, get was called get_bugs
  *get_bugs = \&get;

  # Before 3.4rc1, "history" was get_history.
  *get_history = \&history;
}

###########
# Methods #
###########

# Helper for the comments field of get, search and possible_duplicates
# (Bugzilla::API::V1::BugComment has its own copy). Fetches the revision metadata
# (number of edits and the timestamp of the most recent edit) for a set of
# comments using a single query, and stashes it on each comment object for
# _translate_comment.
#
# The data is only exposed to users who are allowed to edit other people's
# comments; everyone else gets no edit_count/last_change_time keys at all.
# Revisions hidden by an edit-comments admin are only counted for admins.
#
# Comments that were already preloaded are skipped, so callers that batch every
# comment of a request up front turn the later per-bug calls into no-ops.
sub _preload_comment_edit_info {
  my ($self, $comments) = @_;
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
    $comment->{edit_info} = $rows->{$comment->id}
      || {edit_count => 0, last_change_time => undef};
  }
}

# Batch-preloads the comment edit info for every bug about to be passed through
# _bug_to_hash(), so that a multi-bug request runs one aggregation query rather
# than one per bug.
sub _preload_bugs_comment_edit_info {
  my ($self, $bugs, $params) = @_;

  return unless filter_wants $params, 'comments', ['extra'];
  $self->_preload_comment_edit_info([map { @{$_->comments} } @$bugs]);
}

# Comments that Bugzilla::Comment::collapsed flags (tagged with one of the
# 'collapsed_comment_tags' tags, or authored by treeherder) are hidden behind a
# click in the web UI, so they are left out of the API response too unless the
# caller asks for them with
# include_fields=_collapsed_comments. Like the other underscore-prefixed
# include_fields values, it does not imply _default, so callers that want the
# usual fields as well need include_fields=_default,_collapsed_comments.
sub _wants_collapsed_comments {
  my ($params) = @_;
  return grep { $_ eq '_collapsed_comments' } @{$params->{include_fields} || []};
}

# Helper for Bug.get (comments field). Bugzilla::API::V1::BugComment has its
# own copy until the rest of this module is migrated.
sub _translate_comment {
  my ($self, $comment, $filters, $types, $prefix) = @_;
  my $attach_id = $comment->is_about_attachment ? $comment->extra_data : undef;

  my $comment_hash = {
    id            => $self->type('int',      $comment->id),
    bug_id        => $self->type('int',      $comment->bug_id),
    creator       => $self->type('email',    $comment->author->login),
    author        => $self->type('email',    $comment->author->login),
    time          => $self->type('dateTime', $comment->creation_ts),
    creation_time => $self->type('dateTime', $comment->creation_ts),
    is_private    => $self->type('boolean',  $comment->is_private),
    text          => $self->type('string',   $comment->body_full),
    raw_text      => $self->type('string',   $comment->body),
    attachment_id => $self->type('int',      $attach_id),
    count         => $self->type('int',      $comment->count),
  };

  # Only set by _preload_comment_edit_info when the user may edit others' comments
  if (my $edit_info = $comment->{edit_info}) {
    $comment_hash->{edit_count} = $self->type('int', $edit_info->{edit_count});
    $comment_hash->{last_change_time}
      = $self->type('dateTime', $edit_info->{last_change_time});
  }

  if (Bugzilla->params->{use_comment_reactions}) {
    $comment_hash->{reactions} = {};

    foreach my $key (keys %{$comment->reactions}) {
      $comment_hash->{reactions}->{$key} = $self->type('int', $comment->reactions->{$key});
    }
  }

  # Don't load comment tags unless enabled
  if (Bugzilla->params->{'comment_taggers_group'}) {
    $comment_hash->{tags} = [map { $self->type('string', $_) } @{$comment->tags}];
    $comment_hash->{collapsed} = $self->type('boolean', $comment->collapsed);
  }

  return filter($filters, $comment_hash, $types, $prefix);
}

sub get {
  my ($self, $params) = validate(@_, 'ids');
  my $user = Bugzilla->user;

  unless ($user->id) {
    Bugzilla->check_rate_limit("get_bug", remote_ip());
  }
  Bugzilla->switch_to_shadow_db() unless Bugzilla->user->id;

  my $ids = $params->{ids};
  (defined $ids && scalar @$ids)
    || ThrowCodeError('param_required', {param => 'ids'});

  my (@bugs, @faults, @hashes);

  # Cache permissions for bugs. This highly reduces the number of calls to the DB.
  # visible_bugs() is only able to handle bug IDs, so we have to skip aliases.
  my @int = grep { defined $_ && $_ =~ /^\d+$/ } @$ids;
  $user->visible_bugs(\@int);

  foreach my $bug_id (@$ids) {
    my $bug;
    if ($params->{permissive}) {
      eval { $bug = Bugzilla::Bug->check($bug_id); };
      if ($@) {
        push(@faults,
          {id => $bug_id, faultString => $@->faultstring, faultCode => $@->faultcode,});
        undef $@;
        next;
      }
    }
    else {
      $bug = Bugzilla::Bug->check($bug_id);
    }
    push(@bugs, $bug);
  }

  $self->_preload_bugs_comment_edit_info(\@bugs, $params);
  @hashes = map { $self->_bug_to_hash($_, $params) } @bugs;

  # Set the ETag before inserting the update tokens
  # since the tokens will always be unique even if
  # the data has not changed.
  $self->bz_etag(\@hashes);

  $self->_add_update_tokens($params, \@bugs, \@hashes);

  if ($user->id) {
    foreach my $bug (@bugs) {
      Bugzilla->log_user_request($bug->id, undef, 'bug-get');

      # Audit when a non-public bug is viewed including the groups the bug belongs to
      my $groups_in = $bug->groups_in;
      next if !@$groups_in;
      Bugzilla->audit(sprintf 'api: %s viewed non-public bug %d belonging to groups %s',
        $user->login, $bug->id, join ', ', map { $_->name } @$groups_in);
    }
  }

  Bugzilla::Hook::process('webservice_bug_get',
    {webservice => $self, user => $user, params => $params, bug_data => \@hashes,});

  return {bugs => \@hashes, faults => \@faults};
}

# this is a function that gets bug activity for list of bug ids
# it can be called as the following:
# $call = $rpc->call( 'Bug.history', { ids => [1,2] });
sub history {
  my ($self, $params) = validate(@_, 'ids');

  Bugzilla->switch_to_shadow_db();

  my $ids = $params->{ids};
  defined $ids || ThrowCodeError('param_required', {param => 'ids'});

  my $user         = Bugzilla->user;
  my $skip_private = $params->{skip_private} ? 1 : 0;

  if ($skip_private) {
    # Cache permissions for bugs. This highly reduces the number of calls to the DB.
    # visible_bugs() is only able to handle bug IDs, so we have to skip aliases.
    my @int = grep { $_ =~ /^\d+$/ } @$ids;
    $user->visible_bugs(\@int);
  }

  my @return;
  foreach my $bug_id (@$ids) {
    my %item;
    my $bug;

    if ($skip_private) {
      $bug = Bugzilla::Bug->new({id => $bug_id, cache => 1});
      next if $bug->error || !$user->can_see_bug($bug->id);
    } else {
      $bug = Bugzilla::Bug->check($bug_id);
    }

    $bug_id = $bug->id;
    $item{id} = $self->type('int', $bug_id);

    my ($activity)
      = Bugzilla::Bug::GetBugActivity($bug_id, undef, $params->{new_since}, 1);

    my @history;
    foreach my $changeset (@$activity) {
      push(@history, $self->_changeset_to_hash($changeset, $params));
    }

    $item{history} = \@history;

    # alias is returned in case users passes a mixture of ids and aliases
    # then they get to know which bug activity relates to which value
    # they passed
    if (Bugzilla->params->{'usebugaliases'}) {
      $item{alias} = $self->type('string', $bug->alias);
    }
    else {
      # For API reasons, we always want the value to appear, we just
      # don't want it to have a value if aliases are turned off.
      $item{alias} = undef;
    }

    push(@return, \%item);
  }

  return {bugs => \@return};
}

sub search {
  my ($self, $params) = @_;
  my $user = Bugzilla->user;
  my $dbh  = Bugzilla->dbh;

  Bugzilla->switch_to_shadow_db();

  my $match_params = dclone($params);
  delete $match_params->{include_fields};
  delete $match_params->{exclude_fields};

  # Determine whether this is a quicksearch query
  if (exists $match_params->{quicksearch}) {
    my $quicksearch = quicksearch($match_params->{'quicksearch'});
    my $cgi         = Bugzilla::CGI->new($quicksearch);
    $match_params = $cgi->Vars;
  }

  if (defined($match_params->{offset}) and !defined($match_params->{limit})) {
    ThrowCodeError('param_required',
      {param => 'limit', function => 'Bug.search()'});
  }

  my $max_results = Bugzilla->params->{max_search_results};
  unless (defined $match_params->{limit} && $match_params->{limit} == 0) {
    if (!defined $match_params->{limit} || $match_params->{limit} > $max_results) {
      $match_params->{limit} = $max_results;
    }
  }
  else {
    delete $match_params->{limit};
    delete $match_params->{offset};
  }

  # Allow to search only in bug description (initial comment)
  if (defined $match_params->{description}) {
    $match_params->{longdesc} = delete $match_params->{description};
    $match_params->{longdesc_initial} = 1;
  }

  $match_params = Bugzilla::Bug::map_fields($match_params);

  my %options = (fields => ['bug_id']);

  # Find the highest custom field id
  my @field_ids = grep(/^f(\d+)$/, keys %$match_params);
  my $last_field_id = @field_ids ? max @field_ids + 1 : 1;

  # Do special search types for certain fields.
  if (my $change_when = delete $match_params->{'delta_ts'}) {
    $match_params->{"f${last_field_id}"} = 'delta_ts';
    $match_params->{"o${last_field_id}"} = 'greaterthaneq';
    $match_params->{"v${last_field_id}"} = $change_when;
    $last_field_id++;
  }
  if (my $creation_when = delete $match_params->{'creation_ts'}) {
    $match_params->{"f${last_field_id}"} = 'creation_ts';
    $match_params->{"o${last_field_id}"} = 'greaterthaneq';
    $match_params->{"v${last_field_id}"} = $creation_when;
    $last_field_id++;
  }

  # Some fields require a search type such as short desc, keywords, etc.
  foreach my $param (qw(short_desc longdesc status_whiteboard bug_file_loc)) {
    if (defined $match_params->{$param}
      && !defined $match_params->{$param . '_type'})
    {
      $match_params->{$param . '_type'} = 'allwordssubstr';
    }
  }
  if (defined $match_params->{'keywords'}
    && !defined $match_params->{'keywords_type'})
  {
    $match_params->{'keywords_type'} = 'allwords';
  }

  # Backwards compatibility with old method regarding role search
  $match_params->{'reporter'} = delete $match_params->{'creator'}
    if $match_params->{'creator'};
  foreach my $role (qw(assigned_to reporter qa_contact triage_owner commenter cc))
  {
    next if !exists $match_params->{$role};
    my $value = delete $match_params->{$role};
    $match_params->{"f${last_field_id}"} = $role;
    $match_params->{"o${last_field_id}"} = "anywordssubstr";
    $match_params->{"v${last_field_id}"}
      = ref $value ? join(" ", @{$value}) : $value;
    $last_field_id++;
  }

  # If no other parameters have been passed other than limit and offset
  # then we throw error if system is configured to do so.
  if ( !grep(!/^(limit|offset)$/, keys %$match_params)
    && !Bugzilla->params->{search_allow_no_criteria})
  {
    ThrowUserError('buglist_parameters_required');
  }

  # Allow the use of order shortcuts similar to web UI
  if ($match_params->{order}) {

    # Convert the value of the "order" form field into a list of columns
    # by which to sort the results.
    my %order_types = (
      "Bug Number" => ["bug_id"],
      "Importance" => ["priority", "bug_severity"],
      "Assignee"   => ["assigned_to", "bug_status", "priority", "bug_id"],
      "Last Updated" =>
        ["changeddate", "bug_status", "priority", "assigned_to", "bug_id"],
    );
    if ($order_types{$match_params->{order}}) {
      $options{order} = $order_types{$match_params->{order}};
    }
    else {
      $options{order} = [split(/\s*,\s*/, $match_params->{order})];
    }
  }

  $options{params} = $match_params;

  my $search = new Bugzilla::Search(%options);

  # Execute the query.
  my ($data) = $search->data;

  # BMO if the caller only wants the count, that's all we need to return
  if ($params->{count_only}) {
    return {bug_count => $self->type('int', $data)};
  }

  if (!scalar @$data) {
    return {bugs => []};
  }

# Search.pm won't return bugs that the user shouldn't see so no filtering is needed.
  my @bug_ids = map { $_->[0] } @$data;
  my %bug_objects
    = map { $_->id => $_ } @{Bugzilla::Bug->new_from_list(\@bug_ids)};
  my @bugs = map { $bug_objects{$_} } @bug_ids;
  $self->_preload_bugs_comment_edit_info(\@bugs, $params);
  @bugs = map { $self->_bug_to_hash($_, $params) } @bugs;

  return {bugs => \@bugs};
}

sub possible_duplicates {
  my ($self, $params) = validate(@_, 'product');
  my $user = Bugzilla->user;

  Bugzilla->switch_to_shadow_db();

  state $params_type = Dict [
    id                 => Optional [Int],
    product            => Optional [ArrayRef [Str]],
    limit              => Optional [Int],
    summary            => Optional [Str],
    include_fields     => Optional [ArrayRef [Str]],
    Bugzilla_api_token => Optional [Str]
  ];

  ThrowCodeError('param_invalid',
    {function => 'Bug.possible_duplicates', param => 'A param'})
    if !$params_type->check($params);

  my $summary;
  if ($params->{id}) {
    my $bug = Bugzilla::Bug->check({id => $params->{id}, cache => 1});
    $summary = $bug->short_desc;
  }
  elsif ($params->{summary}) {
    $summary = $params->{summary};
  }
  else {
    ThrowCodeError('param_required',
      {function => 'Bug.possible_duplicates', param => 'id or summary'});
  }

  my @products;
  foreach my $name (@{$params->{'product'} || []}) {
    my $object = $user->can_enter_product($name, THROW_ERROR);
    push(@products, $object);
  }

  my $possible_dupes
    = Bugzilla::Bug->possible_duplicates({
    summary => $summary, products => \@products, limit => $params->{limit}
    });

  # If a bug id was used, remove the bug with the same id from the list.
  if ($params->{id}) {
    @$possible_dupes = grep { $_->id != $params->{id} } @$possible_dupes;
  }

  $self->_preload_bugs_comment_edit_info($possible_dupes, $params);
  my @hashes = map { $self->_bug_to_hash($_, $params) } @$possible_dupes;
  $self->_add_update_tokens($params, $possible_dupes, \@hashes);
  return {bugs => \@hashes};
}

sub update {
  my ($self, $params) = validate(@_, 'ids');

  # BMO: Don't allow updating of bugs if disabled
  if (Bugzilla->params->{disable_bug_updates}) {
    ThrowErrorPage(
      'bug/process/updates-disabled.html.tmpl',
      'Bug updates are currently disabled.'
    );
  }

  my $user = Bugzilla->login(LOGIN_REQUIRED);
  my $dbh  = Bugzilla->dbh;

  # We skip certain fields because their set_ methods actually use
  # the external names instead of the internal names.
  $params = Bugzilla::Bug::map_fields($params,
    {summary => 1, platform => 1, severity => 1, type => 1, url => 1});

  my $ids = delete $params->{ids};
  defined $ids || ThrowCodeError('param_required', {param => 'ids'});

  my @bugs = map { Bugzilla::Bug->check($_) } @$ids;

  my %values = %$params;
  $values{other_bugs} = \@bugs;

  if (exists $values{comment} and exists $values{comment}{comment}) {
    $values{comment}{body} = delete $values{comment}{comment};
  }

  # Prevent bugs that could be triggered by specifying fields that
  # have valid "set_" functions in Bugzilla::Bug, but shouldn't be
  # called using those field names.
  delete $values{dependencies};

  my $flags = delete $values{flags};

  foreach my $bug (@bugs) {
    if (!$user->can_edit_product($bug->product_obj->id)) {
      ThrowUserError("product_edit_denied", {product => $bug->product});
    }

    $bug->set_all(\%values);
    if ($flags) {
      my ($old_flags, $new_flags) = extract_flags($flags, $bug);
      $bug->set_flags($old_flags, $new_flags);
    }
  }

  my %all_changes;
  $dbh->bz_start_transaction();
  foreach my $bug (@bugs) {
    $all_changes{$bug->id} = $bug->update();
  }
  $dbh->bz_commit_transaction();

  foreach my $bug (@bugs) {
    $bug->send_changes($all_changes{$bug->id});
  }

  my @result;
  foreach my $bug (@bugs) {
    my %hash = (
      id               => $self->type('int',      $bug->id),
      last_change_time => $self->type('dateTime', $bug->delta_ts),
      changes          => {},
    );

    # alias is returned in case users pass a mixture of ids and aliases,
    # so that they can know which set of changes relates to which value
    # they passed.
    if (Bugzilla->params->{'usebugaliases'}) {
      $hash{alias} = $self->type('string', $bug->alias);
    }
    else {
      # For API reasons, we always want the alias field to appear, we
      # just don't want it to have a value if aliases are turned off.
      $hash{alias} = $self->type('string', '');
    }

    my %changes = %{$all_changes{$bug->id}};
    foreach my $field (keys %changes) {
      my $change = $changes{$field};
      my $api_field = $api_field_names{$field} || $field;

      # We normalize undef to an empty string, so that the API
      # stays consistent for things like Deadline that can become
      # empty.
      $change->[0] = '' if !defined $change->[0];
      $change->[1] = '' if !defined $change->[1];
      $hash{changes}->{$api_field} = {
        removed => $self->type('string', $change->[0]),
        added   => $self->type('string', $change->[1])
      };
    }

    push(@result, \%hash);
  }

  return {bugs => \@result};
}

sub create {
  my ($self, $params) = @_;
  my $dbh = Bugzilla->dbh;

  # BMO: Don't allow updating of bugs if disabled
  if (Bugzilla->params->{disable_bug_updates}) {
    ThrowErrorPage(
      'bug/process/updates-disabled.html.tmpl',
      'Bug updates are currently disabled.'
    );
  }

  Bugzilla->login(LOGIN_REQUIRED);

  # Some fields cannot be sent to Bugzilla::Bug->create
  foreach my $key (qw(login password token)) {
    delete $params->{$key};
  }

  $params = Bugzilla::Bug::map_fields($params);

  # Define the bug file method if missing
  $params->{filed_via} //= 'api';

  my $flags = delete $params->{flags};

  # We start a nested transaction in case flag setting fails
  # we want the bug creation to roll back as well.
  $dbh->bz_start_transaction();

  my $bug = Bugzilla::Bug->create($params);

  # Set bug flags
  if ($flags) {
    my ($flags, $new_flags) = extract_flags($flags, $bug);
    $bug->set_flags($flags, $new_flags);
    $bug->update($bug->creation_ts);
  }

  $dbh->bz_commit_transaction();

  $bug->send_changes();

  return {id => $self->type('int', $bug->bug_id)};
}

sub update_see_also {
  my ($self, $params) = @_;

  # BMO: Don't allow updating of bugs if disabled
  if (Bugzilla->params->{disable_bug_updates}) {
    ThrowErrorPage(
      'bug/process/updates-disabled.html.tmpl',
      'Bug updates are currently disabled.'
    );
  }

  my $user = Bugzilla->login(LOGIN_REQUIRED);

  # Check parameters
  $params->{ids} || ThrowCodeError('param_required', {param => 'id'});
  my ($add, $remove) = @$params{qw(add remove)};
  ($add || $remove)
    or ThrowCodeError('params_required', {params => ['add', 'remove']});

  my @bugs;
  foreach my $id (@{$params->{ids}}) {
    my $bug = Bugzilla::Bug->check($id);
    $user->can_edit_product($bug->product_id)
      || ThrowUserError("product_edit_denied", {product => $bug->product});
    push(@bugs, $bug);
    if ($remove) {
      $bug->remove_see_also($_) foreach @$remove;
    }
    if ($add) {
      $bug->add_see_also($_) foreach @$add;
    }
  }

  my %changes;
  foreach my $bug (@bugs) {
    my $change = $bug->update();
    if (my $see_also = $change->{see_also}) {
      $changes{$bug->id}->{see_also} = {
        removed => [split(', ', $see_also->[0])],
        added   => [split(', ', $see_also->[1])],
      };
    }
    else {
      # We still want a changes entry, for API consistency.
      $changes{$bug->id}->{see_also} = {added => [], removed => []};
    }

    Bugzilla::BugMail::Send($bug->id, {changer => $user});
  }

  return {changes => \%changes};
}

##############################
# Private Helper Subroutines #
##############################

# A helper for get() and search(). This is done in this fashion in order
# to produce a stable API and to explicitly type return values.
# The internals of Bugzilla::Bug are not stable enough to just
# return them directly.

sub _bug_to_hash {
  my ($self, $bug, $params) = @_;
  my $user = Bugzilla->user;

  # All the basic bug attributes are here, in alphabetical order.
  # A bug attribute is "basic" if it doesn't require an additional
  # database call to get the info.
  my %item = %{filter $params,
    {
      alias            => $self->type('string',  $bug->alias),
      id               => $self->type('int',     $bug->bug_id),
      is_confirmed     => $self->type('boolean', $bug->everconfirmed),
      op_sys           => $self->type('string',  $bug->op_sys),
      platform         => $self->type('string',  $bug->rep_platform),
      priority         => $self->type('string',  $bug->priority),
      resolution       => $self->type('string',  $bug->resolution),
      severity         => $self->type('string',  $bug->bug_severity),
      status           => $self->type('string',  $bug->bug_status),
      summary          => $self->type('string',  $bug->short_desc),
      target_milestone => $self->type('string',  $bug->target_milestone),
      type             => $self->type('string',  $bug->bug_type),
      url              => $self->type('string',  $bug->bug_file_loc),
      version          => $self->type('string',  $bug->version),
      whiteboard       => $self->type('string',  $bug->status_whiteboard),
    }
  };

  state $voting_enabled //= $bug->can('votes') ? 1 : 0;
  if ($voting_enabled && filter_wants $params, 'votes') {
    $item{votes} = $self->type('int', $bug->votes);
  }

  # First we handle any fields that require extra work (such as date parsing
  # or SQL calls).
  if (filter_wants $params, 'assigned_to') {
    $item{'assigned_to'} = $self->type('email', $bug->assigned_to->login);
    $item{'assigned_to_detail'}
      = $self->_user_to_hash($bug->assigned_to, $params, undef, 'assigned_to');
  }
  if (filter_wants $params, 'attachments', ['extra']) {
    my @result;
    foreach my $attachment (@{$bug->attachments}) {
      next if $attachment->isprivate && !$user->is_insider;
      push(@result,
           $self->_attachment_to_hash($attachment, $params, ['extra'], 'attachments'));
    }
    $item{'attachments'} = \@result;
  }
  if (filter_wants $params, 'blocks') {
    my @blocks = map { $self->type('int', $_) } @{$bug->blocked};
    $item{'blocks'} = \@blocks;
  }
  if (filter_wants $params, 'classification') {
    $item{classification} = $self->type('string', $bug->classification);
  }
  if (filter_wants $params, 'comments', ['extra']) {
    my @result;
    my $comments
      = $bug->comments({order => 'oldest_to_newest', after => $params->{new_since}});
    $self->_preload_comment_edit_info($comments);
    my $want_collapsed = _wants_collapsed_comments($params);
    foreach my $comment (@$comments) {
      next if $comment->is_private && !$user->is_insider;
      next if $comment->collapsed && !$want_collapsed;
      push(@result,
           $self->_translate_comment($comment, $params, ['extra'], 'comments'));
    }
    $item{'comments'} = \@result;
  }
  if (filter_wants $params, 'component') {
    $item{component} = $self->type('string', $bug->component);
  }
  if (filter_wants $params, 'cc') {
    my @cc = map { $self->type('email', $_) } @{$bug->cc || []};
    $item{'cc'} = \@cc;
    $item{'cc_detail'}
      = [map { $self->_user_to_hash($_, $params, undef, 'cc') } @{$bug->cc_users}];
  }
  if (filter_wants $params, 'creation_time') {
    $item{'creation_time'} = $self->type('dateTime', $bug->creation_ts);
  }
  if (filter_wants $params, 'creator') {
    $item{'creator'} = $self->type('email', $bug->reporter->login);
    $item{'creator_detail'}
      = $self->_user_to_hash($bug->reporter, $params, undef, 'creator');
  }
  if (filter_wants $params, 'depends_on') {
    my @depends_on = map { $self->type('int', $_) } @{$bug->dependson};
    $item{'depends_on'} = \@depends_on;
  }
  if (filter_wants $params, 'description', ['extra']) {
    my $comment = Bugzilla::Comment->match({bug_id => $bug->id, LIMIT => 1})->[0];
    $item{'description'}
      = ($comment && (!$comment->is_private || Bugzilla->user->is_insider))
      ? $comment->body : '';
  }
  if (filter_wants $params, 'dupe_of') {
    $item{'dupe_of'} = $self->type('int', $bug->dup_id);
  }
  if (filter_wants $params, 'duplicates') {
    $item{'duplicates'} = [map { $self->type('int', $_->id) } @{$bug->duplicates}];
  }
  if (filter_wants $params, 'filed_via', ['extra']) {
    $item{'filed_via'} = $self->type('string', $bug->filed_via);
  }
  if (filter_wants $params, 'groups') {
    my @groups = map { $self->type('string', $_->name) } @{$bug->groups_in};
    $item{'groups'} = \@groups;
  }
  if (filter_wants $params, 'history', ['extra']) {
    my @result;
    my ($activity)
      = Bugzilla::Bug::GetBugActivity($bug->id, undef, $params->{new_since}, 1);
    foreach my $changeset (@$activity) {
      push(@result,
           $self->_changeset_to_hash($changeset, $params, ['extra'], 'history'));
    }
    $item{'history'} = \@result;
  }
  if (filter_wants $params, 'is_open') {
    $item{'is_open'} = $self->type('boolean', $bug->status->is_open);
  }
  if (filter_wants $params, 'keywords') {
    my @keywords = map { $self->type('string', $_->name) } @{$bug->keyword_objects};
    $item{'keywords'} = \@keywords;
  }
  if (filter_wants $params, 'last_change_time') {
    $item{'last_change_time'} = $self->type('dateTime', $bug->delta_ts);
  }
  if (filter_wants $params, 'last_change_time_non_bot', ['extra']) {
    $item{'last_change_time_non_bot'}
      = $self->type('dateTime', $bug->delta_ts_non_bot);
  }
  if (filter_wants $params, 'product') {
    $item{product} = $self->type('string', $bug->product);
  }
  if (filter_wants $params, 'qa_contact') {
    my $qa_login = $bug->qa_contact ? $bug->qa_contact->login : '';
    $item{'qa_contact'} = $self->type('email', $qa_login);
    if ($bug->qa_contact) {
      $item{'qa_contact_detail'}
        = $self->_user_to_hash($bug->qa_contact, $params, undef, 'qa_contact');
    }
  }
  if (filter_wants $params, 'triage_owner', ['extra']) {
    my $triage_owner = $bug->component_obj->triage_owner;
    $item{'triage_owner'} = $self->type('email', $triage_owner->login);
    if ($triage_owner->login) {
      $item{'triage_owner_detail'}
        = $self->_user_to_hash($triage_owner, $params, ['extra'], 'triage_owner');
    }
  }
  if (filter_wants $params, 'see_also') {
    my @see_also = map { $self->type('string', $_->name) } @{$bug->see_also};
    $item{'see_also'} = \@see_also;
  }
  if (filter_wants $params, 'flags') {
    $item{'flags'} = [map { $self->_flag_to_hash($_) } @{$bug->flags}];
  }

  # Regressions
  if (Bugzilla->params->{use_regression_fields}) {
    if (filter_wants $params, 'regressed_by') {
      my @regressed_by = map { $self->type('int', $_) } @{$bug->regressed_by};
      $item{'regressed_by'} = \@regressed_by;
    }
    if (filter_wants $params, 'regressions') {
      my @regressions = map { $self->type('int', $_) } @{$bug->regresses};
      $item{'regressions'} = \@regressions;
    }
  }

  # And now custom fields
  my @custom_fields = Bugzilla->active_custom_fields(
    {
      product   => $bug->product_obj,
      component => $bug->component_obj,
      bug_id    => $bug->id
    },
    $self->wants_object,
  );
  foreach my $field (@custom_fields) {
    my $name = $field->name;
    next if !filter_wants($params, $name, ['default', 'custom']);
    $item{$name} = $self->_format_cf_value($field, $bug->$name);
  }

  # Include stored values for CFs not enabled for this product/component,
  # so callers aren't silently missing data when a bug retains a value after
  # its product/component changed.  Multi-select CFs are excluded: they are
  # not preloaded by DB_COLUMNS and each accessor fires a separate SELECT,
  # making them too expensive to include for hidden fields across many bugs.
  my %seen_cf = map { $_->name => 1 } @custom_fields;
  my @hidden_cfs = grep {
    !$seen_cf{$_->name}
      && $_->type != FIELD_TYPE_EXTENSION
      && $_->type != FIELD_TYPE_MULTI_SELECT
  } Bugzilla->active_custom_fields({skip_extensions => 1});
  foreach my $field (@hidden_cfs) {
    my $name = $field->name;
    next if !filter_wants($params, $name, ['default', 'custom']);
    my $raw = $bug->$name;
    next if !defined($raw) || $raw eq '';

    # Single-select fields store the '---' sentinel when unset; treat it as
    # empty so hidden fields left at their default aren't surfaced as noise.
    next if $field->type == FIELD_TYPE_SINGLE_SELECT && $raw eq '---';

    $item{$name} = $self->_format_cf_value($field, $raw);
  }

  # Timetracking fields are only sent if the user can see them.
  if ($user->is_timetracker) {
    if (filter_wants $params, 'estimated_time') {
      $item{'estimated_time'} = $self->type('double', $bug->estimated_time);
    }
    if (filter_wants $params, 'remaining_time') {
      $item{'remaining_time'} = $self->type('double', $bug->remaining_time);
    }
    if (filter_wants $params, 'deadline') {

      # No need to format $bug->deadline specially, because Bugzilla::Bug
      # already does it for us.
      $item{'deadline'} = $self->type('string', $bug->deadline);
    }
    if (filter_wants $params, 'actual_time') {
      $item{'actual_time'} = $self->type('double', $bug->actual_time);
    }
  }

  # The "accessible" bits go here because they have long names and it
  # makes the code look nicer to separate them out.
  if (filter_wants $params, 'is_cc_accessible') {
    $item{'is_cc_accessible'} = $self->type('boolean', $bug->cclist_accessible);
  }
  if (filter_wants $params, 'is_creator_accessible') {
    $item{'is_creator_accessible'}
      = $self->type('boolean', $bug->reporter_accessible);
  }

  # BMO - support for special mentors field
  if (filter_wants $params, 'mentors') {
    $item{'mentors'}
      = [map { $self->type('email', $_->login) } @{$bug->mentors || []}];
    $item{'mentors_detail'}
      = [map { $self->_user_to_hash($_, $params, undef, 'mentors') }
        @{$bug->mentors}];
  }

  if (filter_wants $params, 'comment_count') {
    $item{'comment_count'} = $self->type('int', $bug->comment_count);
  }

  if (filter_wants $params, 'counts', ['extra']) {
    $item{'counts'} = {};

    while (my ($key, $value) = each %{$bug->counts}) {
      $item{'counts'}->{$key} = $self->type('int', $value);
    }
  }

  return \%item;
}

sub _format_cf_value {
  my ($self, $field, $value) = @_;
  if ($field->type == FIELD_TYPE_BUG_ID) {
    return $self->type('int', $value);
  }
  elsif ($field->type == FIELD_TYPE_DATETIME) {
    return defined($value) ? $self->type('dateTime', $value) : undef;
  }
  elsif ($field->type == FIELD_TYPE_DATE) {

    # Date-only fields are returned as YYYY-MM-DD, the same format they are
    # accepted in, like deadline. Converting them to dateTime would append
    # a time and time zone that the value does not have.
    return defined($value) ? $self->type('string', $value) : undef;
  }
  elsif ($field->type == FIELD_TYPE_MULTI_SELECT) {
    return [map { $self->type('string', $_) } @{$value}];
  }
  else {
    return $self->type('string', $value);
  }
}

sub _user_to_hash {
  my ($self, $user, $filters, $types, $prefix) = @_;
  my $item = filter $filters,
    {
    id        => $self->type('int',    $user->id),
    real_name => $self->type('string', $user->name),
    nick      => $self->type('string', $user->nick),
    name      => $self->type('email',  $user->login),
    email     => $self->type('email',  $user->email),
    },
    $types, $prefix;
  return $item;
}

sub _attachment_to_hash {
  my ($self, $attach, $filters, $types, $prefix) = @_;

  my $item = filter $filters,
    {
    creation_time    => $self->type('dateTime', $attach->attached),
    last_change_time => $self->type('dateTime', $attach->modification_time),
    id               => $self->type('int',      $attach->id),
    bug_id           => $self->type('int',      $attach->bug_id),
    file_name        => $self->type('string',   $attach->filename),
    summary          => $self->type('string',   $attach->description),
    description      => $self->type('string',   $attach->description),
    content_type     => $self->type('string',   $attach->contenttype),
    is_private       => $self->type('int',      $attach->isprivate),
    is_obsolete      => $self->type('int',      $attach->isobsolete),
    is_patch         => $self->type('int',      $attach->ispatch),
    },
    $types, $prefix;

  # creator/attacher require an extra lookup, so we only send them if
  # the filter wants them.
  foreach my $field (qw(creator attacher)) {
    if (filter_wants $filters, $field, $types, $prefix) {
      $item->{$field} = $self->type('email', $attach->attacher->login);
    }
  }

  if (filter_wants $filters, 'creator', $types, $prefix) {
    $item->{'creator_detail'}
      = $self->_user_to_hash($attach->attacher, $filters, undef, 'creator');
  }

  if (filter_wants $filters, 'data', $types, $prefix) {
    $item->{'data'} = $self->type('base64', $attach->data);
  }

  if (filter_wants $filters, 'size', $types, $prefix) {
    $item->{'size'} = $self->type('int', $attach->datasize);
  }

  if (filter_wants $filters, 'flags', $types, $prefix) {
    $item->{'flags'} = [map { $self->_flag_to_hash($_) } @{$attach->flags}];
  }

  return $item;
}

sub _changeset_to_hash {
  my ($self, $changeset, $filters, $types, $prefix) = @_;

  my $item = {
    when    => $self->type('dateTime', $changeset->{when}),
    who     => $self->type('email',    $changeset->{who}),
    changes => []
  };

  foreach my $change (@{$changeset->{changes}}) {
    my $field_name     = delete $change->{fieldname};
    my $api_field_type = $api_field_types{$field_name} || 'string';
    my $api_field_name = $api_field_names{$field_name} || $field_name;
    my $attach_id      = delete $change->{attachid};
    my $comment        = delete $change->{comment};

    $change->{field_name}    = $self->type('string',        $api_field_name);
    $change->{removed}       = $self->type($api_field_type, $change->{removed});
    $change->{added}         = $self->type($api_field_type, $change->{added});
    $change->{attachment_id} = $self->type('int', $attach_id) if $attach_id;
    $change->{comment_id}    = $self->type('int', $comment->id) if $comment;
    $change->{comment_count} = $self->type('int', $comment->count) if $comment;

    push (@{$item->{changes}}, $change);
  }

  return filter($filters, $item, $types, $prefix);
}

sub _flag_to_hash {
  my ($self, $flag) = @_;

  my $item = {
    id                => $self->type('int',      $flag->id),
    name              => $self->type('string',   $flag->name),
    type_id           => $self->type('int',      $flag->type_id),
    creation_date     => $self->type('dateTime', $flag->creation_date),
    modification_date => $self->type('dateTime', $flag->modification_date),
    status            => $self->type('string',   $flag->status)
  };

  foreach my $field (qw(setter requestee)) {
    my $field_id = $field . "_id";
    $item->{$field} = $self->type('email', $flag->$field->login)
      if $flag->$field_id;
  }

  return $item;
}

sub _add_update_tokens {
  my ($self, $params, $bugs, $hashes) = @_;

  return if !Bugzilla->user->id;
  return if !filter_wants($params, 'update_token');

  for (my $i = 0; $i < @$bugs; $i++) {
    my $token = issue_hash_token([$bugs->[$i]->id, $bugs->[$i]->delta_ts]);
    $hashes->[$i]->{'update_token'} = $self->type('string', $token);
  }
}

1;

__END__

=head1 NAME

Bugzilla::Webservice::Bug - The API for creating, changing, and getting the
details of bugs.

=head1 DESCRIPTION

This part of the Bugzilla API allows you to file a new bug in Bugzilla,
or get information about bugs that have already been filed.

=head1 METHODS

See L<Bugzilla::WebService> for a description of how parameters are passed,
and what B<STABLE>, B<UNSTABLE>, and B<EXPERIMENTAL> mean.

Although the data input and output is the same for JSON-RPC and REST,
the directions for how to access the data via REST is noted in each method
where applicable.

=head1 Bug Information

=head2 get

B<STABLE>

=over

=item B<Description>

Gets information about particular bugs in the database.

Note: Can also be called as "get_bugs" for compatibility with Bugzilla 3.0 API.

=item B<REST>

To get information about a particular bug using its ID or alias:

GET /bug/<id_or_alias>

The returned data format is the same as below.

=item B<Params>

In addition to the parameters below, this method also accepts the
standard L<include_fields|Bugzilla::WebService/include_fields> and
L<exclude_fields|Bugzilla::WebService/exclude_fields> arguments.

=over

=item C<ids>

An array of numbers and strings.

If an element in the array is entirely numeric, it represents a bug_id
from the Bugzilla database to fetch. If it contains any non-numeric
characters, it is considered to be a bug alias instead, and the bug with
that alias will be loaded.

Note that it's possible for aliases to be disabled in Bugzilla, in which
case you will be told that you have specified an invalid bug_id if you
try to specify an alias. (It will be error 100.)

=item C<permissive> B<EXPERIMENTAL>

C<boolean> Normally, if you request any inaccessible or invalid bug ids,
Bug.get will throw an error. If this parameter is True, instead of throwing an
error we return an array of hashes with a C<id>, C<faultString> and C<faultCode>
for each bug that fails, and return normal information for the other bugs that
were accessible.

=back

=item B<Returns>

Two items are returned:

=over

=item C<bugs>

An array of hashes that contains information about the bugs with
the valid ids. Each hash contains the following items:

These fields are returned by default or by specifying C<_default>
in C<include_fields>.

=over

=item C<actual_time>

C<double> The total number of hours that this bug has taken (so far).

If you are not in the time-tracking group, this field will not be included
in the return value.

=item C<alias>

C<string> The unique alias of this bug.

=item C<assigned_to>

C<string> The login name of the user to whom the bug is assigned.

=item C<assigned_to_detail>

C<hash> A hash containing detailed user information for the assigned_to. To see the
keys included in the user detail hash, see below.

=item C<attachments>

C<array> of hashes containing attachment details of the bug, in the same format
as C<GET /rest/bug/E<lt>idE<gt>/attachment> (see the REST API documentation).

This is an B<extra> field returned only by specifying C<attachments> or
C<_extra> in C<include_fields>.

=item C<blocks>

C<array> of C<int>s. The ids of bugs that are "blocked" by this bug.

=item C<cc>

C<array> of C<string>s. The login names of users on the CC list of this
bug.

=item C<cc_detail>

C<array> of hashes containing detailed user information for each of the cc list
members. To see the keys included in the user detail hash, see below.

=item C<classification>

C<string> The name of the current classification the bug is in.

=item C<comment_count>

C<int> The number of the comments left on this bug.

=item C<comments>

C<array> of hashes containing comment details of the bug. See the comments
section above for the object format.

This is an B<extra> field returned only by specifying C<comments> or C<_extra>
in C<include_fields>.

Comments that are collapsed in the web UI are left out unless
C<_collapsed_comments> is also passed in C<include_fields>, as described for
C<GET /rest/bug/E<lt>idE<gt>/comment> in the REST API documentation.

=item C<component>

C<string> The name of the current component of this bug.

=item C<counts>

B<UNSTABLE>

C<hash> A hash containing the numbers of the items in the following fields:
C<attachments>, C<cc>, C<comments>, C<keywords>, C<blocks>, C<depends_on>,
C<regressed_by>, C<regressions> and C<duplicates>.

This is an B<extra> field returned only by specifying C<counts> or C<_extra> in
C<include_fields>.

=item C<creation_time>

C<dateTime> When the bug was created.

=item C<creator>

C<string> The login name of the person who filed this bug (the reporter).

=item C<creator_detail>

C<hash> A hash containing detailed user information for the creator. To see the
keys included in the user detail hash, see below.

=item C<deadline>

C<string> The day that this bug is due to be completed, in the format
C<YYYY-MM-DD>.

If you are not in the time-tracking group, this field will not be included
in the return value.

=item C<depends_on>

C<array> of C<int>s. The ids of bugs that this bug "depends on".

=item C<description>

C<string> The description (initial comment) of the bug.

This is an B<extra> field returned only by specifying C<description> or
C<_extra> in C<include_fields>.

=item C<dupe_of>

C<int> The bug ID of the bug that this bug is a duplicate of. If this bug
isn't a duplicate of any bug, this will be null.

=item C<duplicates>

C<array> of C<int>s. The ids of bugs that are marked as duplicate of this bug.

=item C<estimated_time>

C<double> The number of hours that it was estimated that this bug would
take.

If you are not in the time-tracking group, this field will not be included
in the return value.

=item C<filed_via>

How the bug was filed, e.g. C<standard_form>.

This is an B<extra> field returned only by specifying C<filed_via> or
C<_extra> in C<include_fields>.

=item C<flags>

An array of hashes containing the information about flags currently set
for the bug. Each flag hash contains the following items:

=over

=item C<id>

C<int> The id of the flag.

=item C<name>

C<string> The name of the flag.

=item C<type_id>

C<int> The type id of the flag.

=item C<creation_date>

C<dateTime> The timestamp when this flag was originally created.

=item C<modification_date>

C<dateTime> The timestamp when the flag was last modified.

=item C<status>

C<string> The current status of the flag.

=item C<setter>

C<string> The login name of the user who created or last modified the flag.

=item C<requestee>

C<string> The login name of the user this flag has been requested to be granted or denied.
Note, this field is only returned if a requestee is set.

=back

=item C<groups>

C<array> of C<string>s. The names of all the groups that this bug is in.

=item C<history>

C<array> of hashes containing change details of the bug. See the history section
below for the object format.

This is an B<extra> field returned only by specifying C<history> or C<_extra>
in C<include_fields>.

=item C<id>

C<int> The unique numeric id of this bug.

=item C<is_cc_accessible>

C<boolean> If true, this bug can be accessed by members of the CC list,
even if they are not in the groups the bug is restricted to.

=item C<is_confirmed>

C<boolean> True if the bug has been confirmed. Usually this means that
the bug has at some point been moved out of the C<UNCONFIRMED> status
and into another open status.

=item C<is_open>

C<boolean> True if this bug is open, false if it is closed.

=item C<is_creator_accessible>

C<boolean> If true, this bug can be accessed by the creator (reporter)
of the bug, even if they're not a member of the groups the bug
is restricted to.

=item C<keywords>

C<array> of C<string>s. Each keyword that is on this bug.

=item C<last_change_time>

C<dateTime> When the bug was last changed.

=item C<op_sys>

C<string> The name of the operating system that the bug was filed against.

=item C<platform>

C<string> The name of the platform (hardware) that the bug was filed against.

=item C<priority>

C<string> The priority of the bug.

=item C<product>

C<string> The name of the product this bug is in.

=item C<qa_contact>

C<string> The login name of the current QA Contact on the bug.

=item C<qa_contact_detail>

C<hash> A hash containing detailed user information for the qa_contact. To see the
keys included in the user detail hash, see below.

=item C<regressed_by>

C<array> of C<int>s. The ids of bugs that introduced this bug.

=item C<regressions>

C<array> of C<int>s. The ids of bugs bugs that are introduced by this bug.

=item C<remaining_time>

C<double> The number of hours of work remaining until work on this bug
is complete.

If you are not in the time-tracking group, this field will not be included
in the return value.

=item C<resolution>

C<string> The current resolution of the bug, or an empty string if the bug
is open.

=item C<see_also>

B<UNSTABLE>

C<array> of C<string>s. The URLs in the See Also field on the bug.

=item C<severity>

C<string> The current severity of the bug.

=item C<status>

C<string> The current status of the bug.

=item C<summary>

C<string> The summary of this bug.

=item C<target_milestone>

C<string> The milestone that this bug is supposed to be fixed by, or for
closed bugs, the milestone that it was fixed for.

=item C<triage_owner>

C<string> The login name of the Triage Owner of the bug's component.

This is an B<extra> field returned only by specifying C<triage_owner> or
C<_extra> in C<include_fields>.

=item C<triage_owner_detail>

C<hash> A hash containing detailed user information for the C<triage_owner>. To
see the keys included in the user detail hash, see below.

As with C<triage_owner>, this is an B<extra> field returned only by specifying
C<triage_owner> or C<_extra> in C<include_fields>.

=item C<type>

C<string> The type of the bug.

=item C<update_token>

C<string> The token that you would have to pass to the F<process_bug.cgi>
page in order to update this bug. This changes every time the bug is
updated.

This field is not returned to logged-out users.

=item C<url>

B<UNSTABLE>

C<string> A URL that demonstrates the problem described in
the bug, or is somehow related to the bug report.

=item C<version>

C<string> The version the bug was reported against.

=item C<whiteboard>

C<string> The value of the "status whiteboard" field on the bug.

=item I<custom fields>

Every custom field in this installation will also be included in the
return value. Most fields are returned as C<string>s. However, some
field types have different return values.

Normally custom fields are returned by default similar to normal bug
fields or you can specify only custom fields by using C<_custom> in
C<include_fields>.

=over

=item Bug ID Fields - C<int>

=item Multiple-Selection Fields - C<array> of C<string>s.

=item Date/Time Fields - C<dateTime>

=back

=item I<user detail hashes>

Each user detail hash contains the following items:

=over

=item C<id>

C<int> The user id for this user.

=item C<real_name>

C<string> The 'real' name for this user, if any.

=item C<nick>

C<string> The user's nickname. Currently this is extracted from the real_name,
name or email field.

=item C<name>

C<string> The user's Bugzilla login.

=item C<email>

C<string> The user's email address. Currently this is the same value as the name.

=back

=back

=item C<faults> B<EXPERIMENTAL>

An array of hashes that contains invalid bug ids with error messages
returned for them. Each hash contains the following items:

=over

=item id

C<int> The numeric bug_id of this bug.

=item faultString

c<string> This will only be returned for invalid bugs if the C<permissive>
argument was set when calling Bug.get, and it is an error indicating that
the bug id was invalid.

=item faultCode

c<int> This will only be returned for invalid bugs if the C<permissive>
argument was set when calling Bug.get, and it is the error code for the
invalid bug error.

=back

=back

=item B<Errors>

=over

=item 100 (Invalid Bug Alias)

If you specified an alias and either: (a) the Bugzilla you're querying
doesn't support aliases or (b) there is no bug with that alias.

=item 101 (Invalid Bug ID)

The bug_id you specified doesn't exist in the database.

=item 102 (Access Denied)

You do not have access to the bug_id you specified.

=back

=item B<History>

=over

=item C<permissive> argument added to this method's params in Bugzilla B<3.4>.

=item The following properties were added to this method's return values
in Bugzilla B<3.4>:

=item REST API call added in Bugzilla B<5.0>

=over

=item For C<bugs>

=over

=item assigned_to

=item component

=item dupe_of

=item is_open

=item priority

=item product

=item resolution

=item severity

=item status

=back

=item C<faults>

=back

=item In Bugzilla B<4.0>, the following items were added to the C<bugs>
return value: C<blocks>, C<cc>, C<classification>, C<creator>,
C<deadline>, C<depends_on>, C<estimated_time>, C<is_cc_accessible>,
C<is_confirmed>, C<is_creator_accessible>, C<groups>, C<keywords>,
C<op_sys>, C<platform>, C<qa_contact>, C<remaining_time>, C<see_also>,
C<target_milestone>, C<update_token>, C<url>, C<version>, C<whiteboard>,
and all custom fields.

=item The C<flags> array was added in Bugzilla B<4.4>.

=item The C<actual_time> item was added to the C<bugs> return value
in Bugzilla B<4.4>.

=item The C<attachments>, C<comment_count>, C<comments>, C<counts>,
C<description>, C<duplicates>, C<filed_via>, C<history>, C<regressed_by>,
C<regressions>, C<triage_owner> and C<type> fields were added in Bugzilla
B<6.0>.

=back

=back

=head2 history

B<EXPERIMENTAL>

=over

=item B<Description>

Gets the history of changes for particular bugs in the database.

=item B<REST>

To get the history for a specific bug ID:

GET /bug/<bug_id>/history

The returned data format will be the same as below.

=item B<Params>

=over

=item C<ids>

An array of numbers and strings.

If an element in the array is entirely numeric, it represents a bug_id
from the Bugzilla database to fetch. If it contains any non-numeric
characters, it is considered to be a bug alias instead, and the data bug
with that alias will be loaded.

item C<new_since>

C<dateTime> If specified, the method will only return changes I<newer>
than this time.

Note that it's possible for aliases to be disabled in Bugzilla, in which
case you will be told that you have specified an invalid bug_id if you
try to specify an alias. (It will be error 100.)

=item C<skip_private> B<EXPERIMENTAL>

C<boolean> Normally, if you request any inaccessible or invalid bug ids, this
method will throw an error. If this parameter is C<True>, these bugs will just
be skipped. In the future, error objects will be returned instead, just like
C<Bug.get> with the C<permissive> parameter provided.

=back

=item B<Returns>

A hash containing a single element, C<bugs>. This is an array of hashes,
containing the following keys:

=over

=item id

C<int> The numeric id of the bug.

=item alias

C<string> The alias of this bug. If there is no alias or aliases are
disabled in this Bugzilla, this will be undef.

=item history

C<array> An array of hashes, each hash having the following keys:

=over

=item when

C<dateTime> The date the bug activity/change happened.

=item who

C<string> The login name of the user who performed the bug change.

=item changes

C<array> An array of hashes which contain all the changes that happened
to the bug at this time (as specified by C<when>). Each hash contains
the following items:

=over

=item field_name

C<string> The name of the bug field that has changed.

=item removed

C<string> The previous value of the bug field which has been deleted
by the change.

=item added

C<string> The new value of the bug field which has been added by the change.

=item attachment_id

C<int> The id of the attachment that was changed. This only appears if
the change was to an attachment, otherwise C<attachment_id> will not be
present in this hash.

=back

=back

=item REST API call added Bugzilla B<5.0>.

=back

=item B<Errors>

The same as L</get>.

=item B<History>

=over

=item Added in Bugzilla B<3.4>.

=item Field names changed to be more consistent with other methods in Bugzilla B<4.4>.

=item As of Bugzilla B<4.4>, field names now match names used by L<Bug.update|/"update"> for consistency.

=back

=back

=head2 possible_duplicates

B<UNSTABLE>

=over

=item B<Description>

Allows a user to find possible duplicate bugs based on a set of keywords
such as a user may use as a bug summary. Optionally the search can be
narrowed down to specific products.

=item B<Params>

=over

=item C<summary> (string) B<Required> - A string of keywords defining
the type of bug you are trying to report.

=item C<product> (array) - One or more product names to narrow the
duplicate search to. If omitted, all bugs are searched.

=back

=item B<Returns>

The same as L</get>.

Note that you will only be returned information about bugs that you
can see. Bugs that you can't see will be entirely excluded from the
results. So, if you want to see private bugs, you will have to first
log in and I<then> call this method.

=item B<Errors>

=over

=item 50 (Param Required)

You must specify a value for C<summary> containing a string of keywords to
search for duplicates.

=back

=item B<History>

=over

=item Added in Bugzilla B<4.0>.

=back

=back

=head2 search

B<UNSTABLE>

=over

=item B<Description>

Allows you to search for bugs based on particular criteria.

=item <REST>

To search for bugs:

GET /bug

The URL parameters and the returned data format are the same as below.

=item B<Params>

Unless otherwise specified in the description of a parameter, bugs are
returned if they match I<exactly> the criteria you specify in these
parameters. That is, we don't match against substrings--if a bug is in
the "Widgets" product and you ask for bugs in the "Widg" product, you
won't get anything.

Criteria are joined in a logical AND. That is, you will be returned
bugs that match I<all> of the criteria, not bugs that match I<any> of
the criteria.

Each parameter can be either the type it says, or an array of the types
it says. If you pass an array, it means "Give me bugs with I<any> of
these values." For example, if you wanted bugs that were in either
the "Foo" or "Bar" products, you'd pass:

 product => ['Foo', 'Bar']

Some Bugzillas may treat your arguments case-sensitively, depending
on what database system they are using. Most commonly, though, Bugzilla is
not case-sensitive with the arguments passed (because MySQL is the
most-common database to use with Bugzilla, and MySQL is not case sensitive).

In addition to the fields listed below, you may also use criteria that
is similar to what is used in the Advanced Search screen of the Bugzilla
UI. This includes fields specified by C<Search by Change History> and
C<Custom Search>. The easiest way to determine what the field names are and what
format Bugzilla expects, is to first construct your query using the
Advanced Search UI, execute it and use the query parameters in they URL
as your key/value pairs for the WebService call. With REST, you can
just reuse the query parameter portion in the REST call itself.

=over

=item C<alias>

C<string> The unique alias for this bug. Note that you can search
by alias even if the alias field is disabled in this Bugzilla, but
it's likely that there won't be any aliases set on bugs, in that case.

=item C<assigned_to>

C<string> The login name of a user that a bug is assigned to.

=item C<component>

C<string> The name of the Component that the bug is in. Note that
if there are multiple Components with the same name, and you search
for that name, bugs in I<all> those Components will be returned. If you
don't want this, be sure to also specify the C<product> argument.

=item C<creation_time>

C<dateTime> Searches for bugs that were created at this time or later.
May not be an array.

=item C<creator>

C<string> The login name of the user who created the bug.

You can also pass this argument with the name C<reporter>, for
backwards compatibility with older Bugzillas.

=item C<description>

C<string> The description (initial comment) of the bug.

=item C<filed_via>

C<string> Searches for bugs that were created with this method.

=item C<id>

C<int> The numeric id of the bug.

=item C<last_change_time>

C<dateTime> Searches for bugs that were modified at this time or later.
May not be an array.

=item C<limit>

C<int> Limit the number of results returned to C<int> records. If the limit
is more than zero and higher than the maximum limit set by the administrator,
then the maximum limit will be used instead. If you set the limit equal to zero,
then all matching results will be returned instead.

=item C<offset>

C<int> Used in conjunction with the C<limit> argument, C<offset> defines
the starting position for the search. For example, given a search that
would return 100 bugs, setting C<limit> to 10 and C<offset> to 10 would return
bugs 11 through 20 from the set of 100.

=item C<op_sys>

C<string> The "Operating System" field of a bug.

=item C<platform>

C<string> The Platform (sometimes called "Hardware") field of a bug.

=item C<priority>

C<string> The Priority field on a bug.

=item C<product>

C<string> The name of the Product that the bug is in.

=item C<resolution>

C<string> The current resolution--only set if a bug is closed. You can
find open bugs by searching for bugs with an empty resolution.

=item C<severity>

C<string> The Severity field on a bug.

=item C<status>

C<string> The current status of a bug (not including its resolution,
if it has one, which is a separate field above).

=item C<summary>

C<string> Searches for substrings in the single-line Summary field on
bugs. If you specify an array, then bugs whose summaries match I<any> of the
passed substrings will be returned.

Note that unlike searching in the Bugzilla UI, substrings are not split
on spaces. So searching for C<foo bar> will match "This is a foo bar"
but not "This foo is a bar". C<['foo', 'bar']>, would, however, match
the second item.

=item C<target_milestone>

C<string> The Target Milestone field of a bug. Note that even if this
Bugzilla does not have the Target Milestone field enabled, you can
still search for bugs by Target Milestone. However, it is likely that
in that case, most bugs will not have a Target Milestone set (it
defaults to "---" when the field isn't enabled).

=item C<qa_contact>

C<string> The login name of the bug's QA Contact. Note that even if
this Bugzilla does not have the QA Contact field enabled, you can
still search for bugs by QA Contact (though it is likely that no bug
will have a QA Contact set, if the field is disabled).

=item C<triage_owner>

C<string> The login name of the Triage Owner of a bug's component.

=item C<type>

C<string> The Type field on a bug.

=item C<url>

C<string> The "URL" field of a bug.

=item C<version>

C<string> The Version field of a bug.

=item C<whiteboard>

C<string> Search the "Status Whiteboard" field on bugs for a substring.
Works the same as the C<summary> field described above, but searches the
Status Whiteboard field.

=item C<count_only>

C<boolean> If count_only set to true, only a single hash key called C<bug_count>
will be returned which is the number of bugs that matched the search.

=item C<quicksearch>

C<string> Search for bugs using quicksearch syntax.

=back

=item B<Returns>

The same as L</get>.

Note that you will only be returned information about bugs that you
can see. Bugs that you can't see will be entirely excluded from the
results. So, if you want to see private bugs, you will have to first
log in and I<then> call this method.

=item B<Errors>

If you specify an invalid value for a particular field, you just won't
get any results for that value.

=over

=item 1000 (Parameters Required)

You may not search without any search terms.

=back

=item B<History>

=over

=item Added in Bugzilla B<3.4>.

=item Searching by C<votes> was removed in Bugzilla B<4.0>.

=item The C<reporter> input parameter was renamed to C<creator>
in Bugzilla B<4.0>.

=item In B<4.2.6> and newer, added the ability to return all results if
C<limit> is set equal to zero. Otherwise maximum results returned are limited
by system configuration.

=item REST API call added in Bugzilla B<5.0>.

=item Updated to allow for full search capability similar to the Bugzilla UI
in Bugzilla B<5.0>.

=item Updated to allow quicksearch capability in Bugzilla B<5.0>.

=item The C<description> field was added in Bugzilla B<6.0>.

=back

=back


=head1 Bug Creation and Modification

=head2 create

B<STABLE>

=over

=item B<Description>

This allows you to create a new bug in Bugzilla. If you specify any
invalid fields, an error will be thrown stating which field is invalid.
If you specify any fields you are not allowed to set, they will just be
set to their defaults or ignored.

You cannot currently set all the items here that you can set on enter_bug.cgi.

The WebService interface may allow you to set things other than those listed
here, but realize that anything undocumented is B<UNSTABLE> and will very
likely change in the future.

=item B<REST>

To create a new bug in Bugzilla:

POST /bug

The params to include in the POST body as well as the returned data format,
are the same as below.

=item B<Params>

Some params must be set, or an error will be thrown. These params are
marked B<Required>.

Some parameters can have defaults set in Bugzilla, by the administrator.
If these parameters have defaults set, you can omit them. These parameters
are marked B<Defaulted>.

Clients that want to be able to interact uniformly with multiple
Bugzillas should always set both the params marked B<Required> and those
marked B<Defaulted>, because some Bugzillas may not have defaults set
for B<Defaulted> parameters, and then this method will throw an error
if you don't specify them.

The descriptions of the parameters below are what they mean when Bugzilla is
being used to track software bugs. They may have other meanings in some
installations.

=over

=item C<product> (string) B<Required> - The name of the product the bug
is being filed against.

=item C<component> (string) B<Required> - The name of a component in the
product above.

=item C<summary> (string) B<Required> - A brief description of the bug being
filed.

=item C<version> (string) B<Required> - A version of the product above;
the version the bug was found in.

=item C<description> (string) B<Defaulted> - The description (initial comment)
of the bug. Some Bugzilla installations require this to not be blank.

=item C<filed_via> (string) B<Defaulted> - How the bug is being filed.
It will be C<api> by default when filing through the API.

=item C<op_sys> (string) B<Defaulted> - The operating system the bug was
discovered on.

=item C<platform> (string) B<Defaulted> - What type of hardware the bug was
experienced on.

=item C<priority> (string) B<Defaulted> - What order the bug will be fixed
in by the developer, compared to the developer's other bugs.

=item C<severity> (string) B<Defaulted> - How severe the bug is.

=item C<type> (string) B<Defaulted> - The basic category of the bug. Some
Bugzilla installations require this to be specified.

=item C<alias> (string) - A brief alias for the bug that can be used
instead of a bug number when accessing this bug. Must be unique in
all of this Bugzilla.

=item C<assigned_to> (username) - A user to assign this bug to, if you
don't want it to be assigned to the component owner.

=item C<cc> (array) - An array of usernames to CC on this bug.

=item C<comment_is_private> (boolean) - If set to true, the description
is private, otherwise it is assumed to be public.

=item C<comment_tags> (array) - An array of strings to add as comment
tags to the description.

=item C<groups> (array) - An array of group names to put this
bug into. You can see valid group names on the Permissions
tab of the Preferences screen, or, if you are an administrator,
in the Groups control panel.
If you don't specify this argument, then the bug will be added into
all the groups that are set as being "Default" for this product. (If
you want to avoid that, you should specify C<groups> as an empty array.)

=item C<qa_contact> (username) - If this installation has QA Contacts
enabled, you can set the QA Contact here if you don't want to use
the component's default QA Contact.

=item C<status> (string) - The status that this bug should start out as.
Note that only certain statuses can be set on bug creation.

=item C<target_milestone> (string) - A valid target milestone for this
product.

=item C<flags>

C<array> An array of hashes with flags to add to the bug. To create a flag,
at least the status and the type_id or name must be provided. An optional
requestee can be passed if the flag type is requestable to a specific user.

=over

=item C<name>

C<string> The name of the flag type.

=item C<type_id>

C<int> The internal flag type id.

=item C<status>

C<string> The flags new status (i.e. "?", "+", "-" or "X" to clear a flag).

=item C<requestee>

C<string> The login of the requestee if the flag type is requestable to a specific user.

=back

=back

In addition to the above parameters, if your installation has any custom
fields, you can set them just by passing in the name of the field and
its value as a string.

=item B<Returns>

A hash with one element, C<id>. This is the id of the newly-filed bug.

=item B<Errors>

=over

=item 51 (Invalid Object)

You specified a field value that is invalid. The error message will have
more details.

=item 103 (Invalid Alias)

The alias you specified is invalid for some reason. See the error message
for more details.

=item 104 (Invalid Field)

One of the drop-down fields has an invalid value, or a value entered in a
text field is too long. The error message will have more detail.

=item 105 (Invalid Component)

You didn't specify a component.

=item 106 (Invalid Product)

Either you didn't specify a product, this product doesn't exist, or
you don't have permission to enter bugs in this product.

=item 107 (Invalid Summary)

You didn't specify a summary for the bug.

=item 116 (Dependency Loop)

You specified values in the C<blocks> and C<depends_on> fields,
or the C<regressions> and C<regressed_by> fields, that would cause a
circular dependency between bugs.

=item 120 (Group Restriction Denied)

You tried to restrict the bug to a group which does not exist, or which
you cannot use with this product.

=item 129 (Flag Status Invalid)

The flag status is invalid.

=item 130 (Flag Modification Denied)

You tried to request, grant, or deny a flag but only a user with the required
permissions may make the change.

=item 131 (Flag not Requestable from Specific Person)

You can't ask a specific person for the flag.

=item 133 (Flag Type not Unique)

The flag type specified matches several flag types. You must specify
the type id value to update or add a flag.

=item 134 (Inactive Flag Type)

The flag type is inactive and cannot be used to create new flags.

=item 135 (Bug Type Required)

You didn't specify a type for the bug.

=item 504 (Invalid User)

Either the QA Contact, Assignee, or CC lists have some invalid user
in them. The error message will have more details.

=back

=item B<History>

=over

=item Before B<3.0.4>, parameters marked as B<Defaulted> were actually
B<Required>, due to a bug in Bugzilla.

=item The C<groups> argument was added in Bugzilla B<4.0>. Before
Bugzilla 4.0, bugs were only added into Mandatory groups by this
method. Since Bugzilla B<4.0.2>, passing an illegal group name will
throw an error. In Bugzilla 4.0 and 4.0.1, illegal group names were
silently ignored.

=item The C<comment_is_private> argument was added in Bugzilla B<4.0>.
Before Bugzilla 4.0, you had to use the undocumented C<commentprivacy>
argument.

=item Error 116 was added in Bugzilla B<4.0>. Before that, dependency
loop errors had a generic code of C<32000>.

=back

=item REST API call added in Bugzilla B<5.0>.

=back


=head2 update

B<UNSTABLE>

=over

=item B<Description>

Allows you to update the fields of a bug. Automatically sends emails
out about the changes.

=item B<REST>

To update the fields of a current bug:

PUT /bug/<bug_id>

The params to include in the PUT body as well as the returned data format,
are the same as below. The C<ids> param will be overridden as it is
pulled from the URL path.

=item B<Params>

=over

=item C<ids>

Array of C<int>s or C<string>s. The ids or aliases of the bugs that
you want to modify.

=back

B<Note>: All following fields specify the values you want to set on the
bugs you are updating.

=over

=item C<alias>

(string) The alias of the bug. You can only set this if you are modifying
a single bug. If there is more than one bug specified in C<ids>, passing in
a value for C<alias> will cause an error to be thrown.

=item C<assigned_to>

C<string> The full login name of the user this bug is assigned to.

=item C<blocks>

=item C<depends_on>

C<hash> These specify the bugs that this bug blocks or depends on,
respectively. To set these, you should pass a hash as the value. The hash
may contain the following fields:

=over

=item C<add> An array of C<int>s. Bug ids to add to this field.

=item C<remove> An array of C<int>s. Bug ids to remove from this field.
If the bug ids are not already in the field, they will be ignored.

=item C<set> An array of C<int>s. An exact set of bug ids to set this
field to, overriding the current value. If you specify C<set>, then C<add>
and  C<remove> will be ignored.

=back

=item C<cc>

C<hash> The users on the cc list. To modify this field, pass a hash, which
may have the following fields:

=over

=item C<add> Array of C<string>s. User names to add to the CC list.
They must be full user names, and an error will be thrown if you pass
in an invalid user name.

=item C<remove> Array of C<string>s. User names to remove from the CC
list. They must be full user names, and an error will be thrown if you
pass in an invalid user name.

=back

=item C<is_cc_accessible>

C<boolean> Whether or not users in the CC list are allowed to access
the bug, even if they aren't in a group that can normally access the bug.

=item C<comment>

C<hash>. A comment on the change. The hash may contain the following fields:

=over

=item C<body> C<string> The actual text of the comment.
B<Note>: For compatibility with the parameters to C<POST /rest/bug/E<lt>idE<gt>/comment>,
you can also call this field C<comment>, if you want.

=item C<is_private> C<boolean> Whether the comment is private or not.
If you try to make a comment private and you don't have the permission
to, an error will be thrown.

=back

=item C<comment_is_private>

C<hash> This is how you update the privacy of comments that are already
on a bug. This is a hash, where the keys are the C<int> id of comments (not
their count on a bug, like #1, #2, #3, but their globally-unique id,
as returned by C<GET /rest/bug/E<lt>idE<gt>/comment>) and the value is a C<boolean> which specifies
whether that comment should become private (C<true>) or public (C<false>).

The comment ids must be valid for the bug being updated. Thus, it is not
practical to use this while updating multiple bugs at once, as a single
comment id will never be valid on multiple bugs.

=item C<comment_tags>

C<array> An array of strings to add as comment tags for the new comment.

=item C<component>

C<string> The Component the bug is in.

=item C<deadline>

C<string> The Deadline field--a date specifying when the bug must
be completed by, in the format C<YYYY-MM-DD>.

=item C<dupe_of>

C<int> The bug that this bug is a duplicate of. If you want to mark
a bug as a duplicate, the safest thing to do is to set this value
and I<not> set the C<status> or C<resolution> fields. They will
automatically be set by Bugzilla to the appropriate values for
duplicate bugs.

=item C<estimated_time>

C<double> The total estimate of time required to fix the bug, in hours.
This is the I<total> estimate, not the amount of time remaining to fix it.

=item C<flags>

C<array> An array of hashes with changes to the flags. The following values
can be specified. At least the status and one of type_id, id, or name must
be specified. If a type_id or name matches a single currently set flag,
the flag will be updated unless new is specified.

=over

=item C<name>

C<string> The name of the flag that will be created or updated.

=item C<type_id>

C<int> The internal flag type id that will be created or updated. You will
need to specify the C<type_id> if more than one flag type of the same name exists.

=item C<status>

C<string> The flags new status (i.e. "?", "+", "-" or "X" to clear a flag).

=item C<requestee>

C<string> The login of the requestee if the flag type is requestable to a specific user.

=item C<id>

C<int> Use id to specify the flag to be updated. You will need to specify the C<id>
if more than one flag is set of the same name.

=item C<new>

C<boolean> Set to true if you specifically want a new flag to be created.

=back

=item C<groups>

C<hash> The groups a bug is in. To modify this field, pass a hash, which
may have the following fields:

=over

=item C<add> Array of C<string>s. The names of groups to add. Passing
in an invalid group name or a group that you cannot add to this bug will
cause an error to be thrown.

=item C<remove> Array of C<string>s. The names of groups to remove. Passing
in an invalid group name or a group that you cannot remove from this bug
will cause an error to be thrown.

=back

=item C<keywords>

C<hash> Keywords on the bug. To modify this field, pass a hash, which
may have the following fields:

=over

=item C<add> An array of C<strings>s. The names of keywords to add to
the field on the bug. Passing something that isn't a valid keyword name
will cause an error to be thrown.

=item C<remove> An array of C<string>s. The names of keywords to remove
from the field on the bug. Passing something that isn't a valid keyword
name will cause an error to be thrown.

=item C<set> An array of C<strings>s. An exact set of keywords to set the
field to, on the bug. Passing something that isn't a valid keyword name
will cause an error to be thrown. Specifying C<set> overrides C<add> and
C<remove>.

=back

=item C<op_sys>

C<string> The Operating System ("OS") field on the bug.

=item C<platform>

C<string> The Platform or "Hardware" field on the bug.

=item C<priority>

C<string> The Priority field on the bug.

=item C<product>

C<string> The name of the product that the bug is in. If you change
this, you will probably also want to change C<target_milestone>,
C<version>, and C<component>, since those have different legal
values in every product.

If you cannot change the C<target_milestone> field, it will be reset to
the default for the product, when you move a bug to a new product.

You may also wish to add or remove groups, as which groups are
valid on a bug depends on the product. Groups that are not valid
in the new product will be automatically removed, and groups which
are mandatory in the new product will be automaticaly added, but no
other automatic group changes will be done.

Note that users can only move a bug into a product if they would
normally have permission to file new bugs in that product.

=item C<qa_contact>

C<string> The full login name of the bug's QA Contact.

=item C<is_creator_accessible>

C<boolean> Whether or not the bug's reporter is allowed to access
the bug, even if they aren't in a group that can normally access
the bug.

=item C<regressed_by>

C<array> of C<int>s. The ids of bugs that introduced this bug.

=item C<regressions>

C<array> of C<int>s. The ids of bugs bugs that are introduced by this bug.

=item C<remaining_time>

C<double> How much work time is remaining to fix the bug, in hours.
If you set C<work_time> but don't explicitly set C<remaining_time>,
then the C<work_time> will be deducted from the bug's C<remaining_time>.

=item C<reset_assigned_to>

C<boolean> If true, the C<assigned_to> field will be reset to the
default for the component that the bug is in. (If you have set the
component at the same time as using this, then the component used
will be the new component, not the old one.)

=item C<reset_qa_contact>

C<boolean> If true, the C<qa_contact> field will be reset  to the
default for the component that the bug is in. (If you have set the
component at the same time as using this, then the component used
will be the new component, not the old one.)

=item C<resolution>

C<string> The current resolution. May only be set if you are closing
a bug or if you are modifying an already-closed bug. Attempting to set
the resolution to I<any> value (even an empty or null string) on an
open bug will cause an error to be thrown.

If you change the C<status> field to an open status, the resolution
field will automatically be cleared, so you don't have to clear it
manually.

=item C<see_also>

C<hash> The See Also field on a bug, specifying URLs to bugs in other
bug trackers. To modify this field, pass a hash, which may have the
following fields:

=over

=item C<add> An array of C<strings>s. URLs to add to the field.
Each URL must be a valid URL to a bug-tracker, or an error will
be thrown.

=item C<remove> An array of C<string>s. URLs to remove from the field.
Invalid URLs will be ignored.

=back

=item C<severity>

C<string> The Severity field of a bug.

=item C<status>

C<string> The status you want to change the bug to. Note that if
a bug is changing from open to closed, you should also specify
a C<resolution>.

=item C<summary>

C<string> The Summary field of the bug.

=item C<target_milestone>

C<string> The bug's Target Milestone.

=item C<type>

C<string> The Type field on the bug.

=item C<url>

C<string> The "URL" field of a bug.

=item C<version>

C<string> The bug's Version field.

=item C<whiteboard>

C<string> The Status Whiteboard field of a bug.

=item C<work_time>

C<double> The number of hours worked on this bug as part of this change.
If you set C<work_time> but don't explicitly set C<remaining_time>,
then the C<work_time> will be deducted from the bug's C<remaining_time>.

=back

You can also set the value of any custom field by passing its name as
a parameter, and the value to set the field to. For multiple-selection
fields, the value should be an array of strings.

=item B<Returns>

A C<hash> with a single field, "bugs". This points to an array of hashes
with the following fields:

=over

=item C<id>

C<int> The id of the bug that was updated.

=item C<alias>

C<string> The alias of the bug that was updated, if aliases are enabled and
this bug has an alias.

=item C<last_change_time>

C<dateTime> The exact time that this update was done at, for this bug.
If no update was done (that is, no fields had their values changed and
no comment was added) then this will instead be the last time the bug
was updated.

=item C<changes>

C<hash> The changes that were actually done on this bug. The keys are
the names of the fields that were changed, and the values are a hash
with two keys:

=over

=item C<added> (C<string>) The values that were added to this field,
possibly a comma-and-space-separated list if multiple values were added.

=item C<removed> (C<string>) The values that were removed from this
field, possibly a comma-and-space-separated list if multiple values were
removed.

=back

=back

Here's an example of what a return value might look like:

 {
   bugs => [
     {
       id    => 123,
       alias => 'foo',
       last_change_time => '2010-01-01T12:34:56',
       changes => {
         status => {
           removed => 'NEW',
           added   => 'ASSIGNED'
         },
         keywords => {
           removed => 'bar',
           added   => 'qux, quo, qui',
         }
       },
     }
   ]
 }

Currently, some fields are not tracked in changes: C<comment>,
C<comment_is_private>, and C<work_time>. This means that they will not
show up in the return value even if they were successfully updated.
This may change in a future version of Bugzilla.

=item B<Errors>

This function can throw all of the errors that L</get>, L</create>,
and C<POST /rest/bug/E<lt>idE<gt>/comment> can throw, plus:

=over

=item 50 (Empty Field)

You tried to set some field to be empty, but that field cannot be empty.
The error message will have more details.

=item 52 (Input Not A Number)

You tried to set a numeric field to a value that wasn't numeric.

=item 54 (Number Too Large)

You tried to set a numeric field to a value larger than that field can
accept.

=item 55 (Number Too Small)

You tried to set a negative value in a numeric field that does not accept
negative values.

=item 56 (Bad Date/Time)

You specified an invalid date or time in a date/time field (such as
the C<deadline> field or a custom date/time field).

=item 112 (See Also Invalid)

You attempted to add an invalid value to the C<see_also> field.

=item 115 (Permission Denied)

You don't have permission to change a particular field to a particular value.
The error message will have more detail.

=item 116 (Dependency Loop)

You specified values in the C<blocks> and C<depends_on> fields,
or the C<regressions> and C<regressed_by> fields, that would cause a
circular dependency between bugs.

=item 117 (Invalid Comment ID)

You specified a comment id in C<comment_is_private> that isn't on this bug.

=item 118 (Duplicate Loop)

You specified a value for C<dupe_of> that causes an infinite loop of
duplicates.

=item 119 (dupe_of Required)

You changed the resolution to C<DUPLICATE> but did not specify a value
for the C<dupe_of> field.

=item 120 (Group Add/Remove Denied)

You tried to add or remove a group that you don't have permission to modify
for this bug, or you tried to add a group that isn't valid in this product.

=item 121 (Resolution Required)

You tried to set the C<status> field to a closed status, but you didn't
specify a resolution.

=item 122 (Resolution On Open Status)

This bug has an open status, but you specified a value for the C<resolution>
field.

=item 123 (Invalid Status Transition)

You tried to change from one status to another, but the status workflow
rules don't allow that change.

=item 129 (Flag Status Invalid)

The flag status is invalid.

=item 130 (Flag Modification Denied)

You tried to request, grant, or deny a flag but only a user with the required
permissions may make the change.

=item 131 (Flag not Requestable from Specific Person)

You can't ask a specific person for the flag.

=item 132 (Flag not Unique)

The flag specified has been set multiple times. You must specify the id
value to update the flag.

=item 133 (Flag Type not Unique)

The flag type specified matches several flag types. You must specify
the type id value to update or add a flag.

=item 134 (Inactive Flag Type)

The flag type is inactive and cannot be used to create new flags.

=back

=item B<History>

=over

=item Added in Bugzilla B<4.0>.

=item REST API call added Bugzilla B<5.0>.

=item Added C<new_since> parameter if Bugzilla B<5.0>.

=back

=back


=head2 update_see_also

B<EXPERIMENTAL>

=over

=item B<Description>

Adds or removes URLs for the "See Also" field on bugs. These URLs must
point to some valid bug in some Bugzilla installation or in Launchpad.

=item B<Params>

=over

=item C<ids>

Array of C<int>s or C<string>s. The ids or aliases of bugs that you want
to modify.

=item C<add>

Array of C<string>s. URLs to Bugzilla bugs. These URLs will be added to
the See Also field. They must be valid URLs to C<show_bug.cgi> in a
Bugzilla installation or to a bug filed at launchpad.net.

If the URLs don't start with C<http://> or C<https://>, it will be assumed
that C<http://> should be added to the beginning of the string.

It is safe to specify URLs that are already in the "See Also" field on
a bug--they will just be silently ignored.

=item C<remove>

Array of C<string>s. These URLs will be removed from the See Also field.
You must specify the full URL that you want removed. However, matching
is done case-insensitively, so you don't have to specify the URL in
exact case, if you don't want to.

If you specify a URL that is not in the See Also field of a particular bug,
it will just be silently ignored. Invaild URLs are currently silently ignored,
though this may change in some future version of Bugzilla.

=back

NOTE: If you specify the same URL in both C<add> and C<remove>, it will
be I<added>. (That is, C<add> overrides C<remove>.)

=item B<Returns>

C<changes>, a hash where the keys are numeric bug ids and the contents
are a hash with one key, C<see_also>. C<see_also> points to a hash, which
contains two keys, C<added> and C<removed>. These are arrays of strings,
representing the actual changes that were made to the bug.

Here's a diagram of what the return value looks like for updating
bug ids 1 and 2:

 {
   changes => {
       1 => {
           see_also => {
               added   => (an array of bug URLs),
               removed => (an array of bug URLs),
           }
       },
       2 => {
           see_also => {
               added   => (an array of bug URLs),
               removed => (an array of bug URLs),
           }
       }
   }
 }

This return value allows you to tell what this method actually did. It is in
this format to be compatible with the return value of a future C<Bug.update>
method.

=item B<Errors>

This method can throw all of the errors that L</get> throws, plus:

=over

=item 109 (Bug Edit Denied)

You did not have the necessary rights to edit the bug.

=item 112 (Invalid Bug URL)

One of the URLs you provided did not look like a valid bug URL.

=item 115 (See Also Edit Denied)

You did not have the necessary rights to edit the See Also field for
this bug.

=back

=item B<History>

=over

=item Added in Bugzilla B<3.4>.

=item Before Bugzilla B<3.6>, error 115 had a generic error code of 32000.

=back

=back
