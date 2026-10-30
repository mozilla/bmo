# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Bug;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Digest::MD5 qw(md5_base64);
use List::Util qw(max);
use List::MoreUtils qw(uniq);
use Storable qw(freeze);
use Types::Standard -all;

use Bugzilla::API::V1::Util;
use Bugzilla::App::Plugin::Error;
use Bugzilla::Bug;
use Bugzilla::Comment;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Hook;
use Bugzilla::Search;
use Bugzilla::Search::Quicksearch;
use Bugzilla::Token qw(issue_hash_token);
use Bugzilla::Util qw(remote_ip trim);
use Bugzilla::WebService;
use Bugzilla::WebService::Server;
use Bugzilla::WebService::Util qw(extract_flags filter filter_wants
  merge_request_params strip_request_params validate);

our %api_field_types = (
  %{{map { $_ => 'double' } Bugzilla::Bug::NUMERIC_COLUMNS()}},
  %{{map { $_ => 'dateTime' } Bugzilla::Bug::DATE_COLUMNS()}},
);

our %api_field_names = reverse %{Bugzilla::Bug::FIELD_MAP()};

# This doesn't normally belong in FIELD_MAP, but we do want to translate
# "bug_group" back into "groups".
$api_field_names{'bug_group'} = 'groups';

sub setup_routes {
  my ($class, $r) = @_;
  my $routes
    = $r->under('/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  # /bug/possible_duplicates before /bug/#id, which would match it too.
  my @routes = (
    ['/bug'                     => {get => 'search', post => 'create'}],
    ['/bug/possible_duplicates' => {get => 'possible_duplicates'}],
    ['/bug/#id'                 => {get => 'get',     put => 'update'}],
    ['/bug/#id/history'         => {get => 'history'}],
  );
  foreach my $route (@routes) {
    my ($path, $actions) = @$route;
    foreach my $method (sort keys %$actions) {
      $routes->$method($path)->to("V1::Bug#$actions->{$method}");
    }
    $routes->options($path)
      ->to('V1::Bug#options', allow => join(', ', map {uc} sort keys %$actions));
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

# GET /bug/<id> and, with the ids in the query string, GET /bug/
sub get {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  my ($params, $responded) = $self->_request_params('ids');
  return if $responded;

  unless ($user->id) {
    Bugzilla->check_rate_limit("get_bug", remote_ip());
  }
  Bugzilla->switch_to_shadow_db() unless $user->id;

  my $ids = $params->{ids};
  (defined $ids && scalar @$ids)
    || return $self->code_error('param_required', {param => 'ids'});

  # Cache permissions for bugs. This highly reduces the number of calls to the DB.
  # visible_bugs() is only able to handle bug IDs, so we have to skip aliases.
  my @int = grep { defined $_ && $_ =~ /^\d+$/ } @$ids;
  $user->visible_bugs(\@int);

  my (@bugs, @faults);
  foreach my $bug_id (@$ids) {
    if ($params->{permissive}) {
      my $bug = eval { Bugzilla::Bug->check($bug_id) };
      if (!$bug) {
        push @faults, $self->_fault($bug_id, $@);
        next;
      }
      push @bugs, $bug;
    }
    else {
      push @bugs, Bugzilla::Bug->check($bug_id);
    }
  }

  $self->_preload_bugs_comment_edit_info(\@bugs, $params);
  my @hashes = map { $self->_bug_to_hash($_, $params) } @bugs;

  # Before the update tokens, which change on every request.
  my $etag = _etag({bugs => \@hashes, faults => \@faults});
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

  return $self->_render_with_etag({bugs => \@hashes, faults => \@faults}, $etag);
}

# GET /bug/<id>/history
sub history {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  my ($params, $responded) = $self->_request_params('ids');
  return if $responded;
  _convert_dates($params, 'new_since');

  Bugzilla->switch_to_shadow_db();

  my $ids = $params->{ids};
  defined $ids || return $self->code_error('param_required', {param => 'ids'});

  my $skip_private = $params->{skip_private} ? 1 : 0;

  if ($skip_private) {

    # Cache permissions for bugs. This highly reduces the number of calls to the DB.
    # visible_bugs() is only able to handle bug IDs, so we have to skip aliases.
    my @int = grep { $_ =~ /^\d+$/ } @$ids;
    $user->visible_bugs(\@int);
  }

  my @return;
  foreach my $bug_id (@$ids) {
    my $bug;

    if ($skip_private) {
      $bug = Bugzilla::Bug->new({id => $bug_id, cache => 1});
      next if $bug->error || !$user->can_see_bug($bug->id);
    }
    else {
      $bug = Bugzilla::Bug->check($bug_id);
    }

    my ($activity)
      = Bugzilla::Bug::GetBugActivity($bug->id, undef, $params->{new_since}, 1);

    push @return, {
      id      => $self->type('int', $bug->id),
      history => [map { $self->changeset_to_hash($_, $params) } @$activity],

      # alias is returned in case users passes a mixture of ids and aliases
      # then they get to know which bug activity relates to which value
      # they passed. For API reasons, we always want the value to appear, we
      # just don't want it to have a value if aliases are turned off.
      alias => Bugzilla->params->{'usebugaliases'}
      ? $self->type('string', $bug->alias)
      : undef,
    };
  }

  return $self->_render_with_etag({bugs => \@return});
}

# GET /bug
sub search {
  my ($self) = @_;

  # The legacy server routed GET /bug/ (trailing slash) to get, and Mojo
  # matches it to the /bug route.
  return $self->get if $self->req->url->path->trailing_slash;

  $self->bugzilla->login;
  my ($params, $responded) = $self->_request_params;
  return if $responded;
  _convert_dates($params, 'last_change_time', 'creation_time');

  Bugzilla->switch_to_shadow_db();

  my $match_params = strip_request_params($params);

  # Determine whether this is a quicksearch query
  if (exists $match_params->{quicksearch}) {

    # Redirects call exit, which would end the Mojo worker: quicksearch
    # redirects to the search form when 'load' is set, and Bugzilla::CGI->new
    # redirects to urlbase on the attachment host unless it can't see the
    # controller.
    my $new_cgi = sub {
      local Bugzilla->request_cache->{mojo_controller};
      return Bugzilla::CGI->new(@_);
    };

    # quicksearch() adds its params to those of Bugzilla->cgi and returns
    # them all. As on the legacy server, start from the request's other params
    # (limit, order...). Outside of a CGI request Bugzilla->cgi is built from
    # the command line (e.g. keywords=daemon), so it can't be used.
    my %other_params = %$match_params;
    my $searchstring = delete $other_params{quicksearch};
    delete $other_params{load};
    local Bugzilla->request_cache->{cgi} = $new_cgi->(\%other_params);
    my $quicksearch = quicksearch($searchstring);
    my $cgi         = $new_cgi->($quicksearch);
    $match_params = $cgi->Vars;
  }

  if (defined($match_params->{offset}) and !defined($match_params->{limit})) {
    return $self->code_error('param_required',
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

  # After the highest custom field number, so that the conditions added below
  # don't replace the caller's.
  my $last_field_id
    = max(0, map { /^f(\d+)$/ ? $1 : () } keys %$match_params) + 1;

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
    $match_params->{"v${last_field_id}"} = ref $value ? join(" ", @{$value}) : $value;
    $last_field_id++;
  }

  # If no other parameters have been passed other than limit and offset
  # then we throw error if system is configured to do so.
  if ( !grep(!/^(limit|offset)$/, keys %$match_params)
    && !Bugzilla->params->{search_allow_no_criteria})
  {
    return $self->user_error('buglist_parameters_required');
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

  my $search = Bugzilla::Search->new(%options);

  # Execute the query.
  my ($data) = $search->data;

  # BMO if the caller only wants the count, that's all we need to return
  if ($params->{count_only}) {
    return $self->_render_with_etag({bug_count => $self->type('int', $data)});
  }

  if (!scalar @$data) {
    return $self->_render_with_etag({bugs => []});
  }

  # Search.pm won't return bugs that the user shouldn't see so no filtering
  # is needed.
  my @bug_ids = map { $_->[0] } @$data;
  my %bug_objects
    = map { $_->id => $_ } @{Bugzilla::Bug->new_from_list(\@bug_ids)};
  my @bugs = map { $bug_objects{$_} } @bug_ids;
  $self->_preload_bugs_comment_edit_info(\@bugs, $params);
  @bugs = map { $self->_bug_to_hash($_, $params) } @bugs;

  return $self->_render_with_etag({bugs => \@bugs});
}

# GET /bug/possible_duplicates
sub possible_duplicates {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  my ($params, $responded) = $self->_request_params('product');
  return if $responded;

  Bugzilla->switch_to_shadow_db();

  state $params_type = Dict [
    id             => Optional [Int],
    product        => Optional [ArrayRef [Str]],
    limit          => Optional [Int],
    summary        => Optional [Str],
    include_fields => Optional [ArrayRef [Str]],
  ];

  # Credentials are not params of this method. include_fields is, and
  # exclude_fields is rejected.
  my $checked = strip_request_params($params);
  exists $params->{$_} and $checked->{$_} = $params->{$_}
    for qw(include_fields exclude_fields);
  return $self->code_error('param_invalid',
    {function => 'Bug.possible_duplicates', param => 'A param'})
    if !$params_type->check($checked);

  my $summary;
  if ($params->{id}) {
    my $bug = Bugzilla::Bug->check({id => $params->{id}, cache => 1});
    $summary = $bug->short_desc;
  }
  elsif ($params->{summary}) {
    $summary = $params->{summary};
  }
  else {
    return $self->code_error('param_required',
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
  return $self->render(json => {bugs => \@hashes});
}

# PUT /bug/<id>
sub update {
  my ($self) = @_;

  # BMO: Don't allow updating of bugs if disabled
  return Bugzilla::API::V1::Util->updates_disabled($self)
    if Bugzilla->params->{disable_bug_updates};

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $responded) = $self->_request_params('ids');
  return if $responded;
  _convert_dates($params, _datetime_custom_fields());

  my $dbh = Bugzilla->dbh;

  # We skip certain fields because their set_ methods actually use
  # the external names instead of the internal names.
  $params = Bugzilla::Bug::map_fields(strip_request_params($params),
    {summary => 1, platform => 1, severity => 1, type => 1, url => 1});

  my $ids = delete $params->{ids};
  defined $ids || return $self->code_error('param_required', {param => 'ids'});

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
      return $self->user_error("product_edit_denied", {product => $bug->product});
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

      # alias is returned in case users pass a mixture of ids and aliases,
      # so that they can know which set of changes relates to which value
      # they passed. For API reasons, we always want the alias field to
      # appear, we just don't want it to have a value if aliases are turned
      # off.
      alias => $self->type('string',
        Bugzilla->params->{'usebugaliases'} ? $bug->alias : ''),
    );

    my %changes = %{$all_changes{$bug->id}};
    foreach my $field (keys %changes) {
      my $change    = $changes{$field};
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

  return $self->render(json => {bugs => \@result});
}

# POST /bug
sub create {
  my ($self) = @_;

  # BMO: Don't allow updating of bugs if disabled
  return Bugzilla::API::V1::Util->updates_disabled($self)
    if Bugzilla->params->{disable_bug_updates};

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  my ($params, $responded) = $self->_request_params;
  return if $responded;
  _convert_dates($params, _datetime_custom_fields());

  my $dbh = Bugzilla->dbh;

  # Some fields cannot be sent to Bugzilla::Bug->create
  $params = Bugzilla::Bug::map_fields(strip_request_params($params));

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

  # The legacy route asked for 201 but the server used 200.
  return $self->render(json => {id => $self->type('int', $bug->bug_id)});
}

# The params of a request, as the legacy REST server built them. On GET, the
# query string, with a value per param, or a list for a param sent more than
# once; the id in the path is added to the ids there. Otherwise the query
# string and the request body, and the id in the path only when neither of them
# has ids. @list_params are always lists, and include_fields/exclude_fields are
# split on commas and spaces.
#
# Also sets Bugzilla->input_params, which extensions read in bug hooks (such
# as Needinfo's needinfo_from) and which wants_object() uses.
#
# Returns ($params, $responded): $responded is true when an error response has
# already been rendered (the error helpers return 0, so their result can't be
# used for this).
sub _request_params {
  my ($self, @list_params) = @_;

  my $params;
  if ($self->req->method eq 'GET') {
    $params = {};
    foreach my $name (@{$self->req->query_params->names}) {
      my $values = $self->req->query_params->every_param($name);
      $params->{$name} = @$values > 1 ? $values : $values->[0];
    }
  }
  else {
    my $error;
    ($params, $error) = merge_request_params($self, \@list_params);
    if ($error) {
      $self->user_error($error);
      return (undef, 1);
    }
  }

  # As legacy validate(): a single value becomes a list, and anything but a
  # list of plain values (e.g. a hash of conditions) is invalid_params.
  (undef, $params) = validate($self, $params, @list_params) if @list_params;

  if (defined(my $id = $self->stash('id'))) {
    if ($self->req->method eq 'GET') {
      $params->{ids} = [uniq($id, @{$params->{ids} || []})];
    }
    else {
      $params->{ids} //= [$id];
    }
  }

  Bugzilla::API::V1::Util->split_include_exclude($params);

  Bugzilla->input_params($params);
  return ($params, 0);
}

# Converts the given date params to the database timezone, as the legacy
# server did for the fields listed in DATE_FIELDS.
sub _convert_dates {
  my ($params, @fields) = @_;
  my $server = 'Bugzilla::WebService::Server';

  foreach my $field (@fields) {
    my $value = $params->{$field} // next;
    $params->{$field}
      = ref $value
      ? [map { $server->datetime_format_inbound($_) } @$value]
      : $server->datetime_format_inbound($value);
  }
}

# Datetime custom fields, converted on create and update. Date-only fields are
# left out so they are passed through as YYYY-MM-DD, since converting them
# would append a time component that _check_date_field rejects.
sub _datetime_custom_fields {
  return map { $_->name } grep { $_->type == FIELD_TYPE_DATETIME }
    Bugzilla->active_custom_fields({skip_extensions => 1});
}

# Clients send back the ETag of get, search and history to know if the bugs
# changed, as with the legacy REST server.
sub _etag {
  my ($data) = @_;
  local $Storable::canonical = 1;
  return md5_base64(freeze($data));
}

sub _render_with_etag {
  my ($self, $json, $etag) = @_;
  return $self->rendered(304) if $self->is_fresh(etag => $etag // _etag($json));
  return $self->render(json => $json);
}

# A permissive get's entry for a bug that can't be returned, from the error
# Bugzilla::Bug->check() just threw: in this usage mode, Throw*Error() leaves
# it in the stash. Any other exception is not about the bug, and fails the
# request as without permissive.
sub _fault {
  my ($self, $bug_id, $exception) = @_;
  my $stash = $self->stash;
  my ($type, $error, $vars) = delete @$stash{qw(type error vars)};
  die $exception if !$error;

  my ($message, $code)
    = Bugzilla::App::Plugin::Error::error_message_and_code($type, $error,
    $vars || {});

  return {
    id          => $bug_id,
    faultString => trim($message),
    faultCode   => $self->type('int', $code),
  };
}

# Batch-preloads the comment edit info for every bug about to be passed through
# _bug_to_hash(), so that a multi-bug request runs one aggregation query rather
# than one per bug.
sub _preload_bugs_comment_edit_info {
  my ($self, $bugs, $params) = @_;

  return unless filter_wants $params, 'comments', ['extra'];
  Bugzilla::API::V1::Util->preload_comment_edit_info(
    [map { @{$_->comments} } @$bugs]);
}

# A helper for get() and search(). This is done in this fashion in order
# to produce a stable API and to explicitly type return values.
# The internals of Bugzilla::Bug are not stable enough to just
# return them directly.
sub _bug_to_hash {
  my ($self, $bug, $params) = @_;
  my $user = Bugzilla->user;
  my $util = 'Bugzilla::API::V1::Util';

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
      = $util->user_to_hash($bug->assigned_to, $params, undef, 'assigned_to');
  }
  if (filter_wants $params, 'attachments', ['extra']) {
    my @result;
    foreach my $attachment (@{$bug->attachments}) {
      next if $attachment->isprivate && !$user->is_insider;
      push(@result,
        $util->attachment_to_hash($attachment, $params, ['extra'], 'attachments'));
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
    $util->preload_comment_edit_info($comments);
    my $want_collapsed = $util->wants_collapsed_comments($params);
    foreach my $comment (@$comments) {
      next if $comment->is_private && !$user->is_insider;
      next if $comment->collapsed  && !$want_collapsed;
      push(@result,
        $util->comment_to_hash($comment, $params, ['extra'], 'comments'));
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
      = [map { $util->user_to_hash($_, $params, undef, 'cc') } @{$bug->cc_users}];
  }
  if (filter_wants $params, 'creation_time') {
    $item{'creation_time'} = $self->type('dateTime', $bug->creation_ts);
  }
  if (filter_wants $params, 'creator') {
    $item{'creator'} = $self->type('email', $bug->reporter->login);
    $item{'creator_detail'}
      = $util->user_to_hash($bug->reporter, $params, undef, 'creator');
  }
  if (filter_wants $params, 'depends_on') {
    my @depends_on = map { $self->type('int', $_) } @{$bug->dependson};
    $item{'depends_on'} = \@depends_on;
  }
  if (filter_wants $params, 'description', ['extra']) {
    my $comment = Bugzilla::Comment->match({bug_id => $bug->id, LIMIT => 1})->[0];
    $item{'description'}
      = ($comment && (!$comment->is_private || Bugzilla->user->is_insider))
      ? $comment->body
      : '';
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
        $self->changeset_to_hash($changeset, $params, ['extra'], 'history'));
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
        = $util->user_to_hash($bug->qa_contact, $params, undef, 'qa_contact');
    }
  }
  if (filter_wants $params, 'triage_owner', ['extra']) {
    my $triage_owner = $bug->component_obj->triage_owner;
    $item{'triage_owner'} = $self->type('email', $triage_owner->login);
    if ($triage_owner->login) {
      $item{'triage_owner_detail'}
        = $util->user_to_hash($triage_owner, $params, ['extra'], 'triage_owner');
    }
  }
  if (filter_wants $params, 'see_also') {
    my @see_also = map { $self->type('string', $_->name) } @{$bug->see_also};
    $item{'see_also'} = \@see_also;
  }
  if (filter_wants $params, 'flags') {
    $item{'flags'} = [map { $util->flag_to_hash($_) } @{$bug->flags}];
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
    Bugzilla::WebService->wants_object,
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
  my %seen_cf    = map { $_->name => 1 } @custom_fields;
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
      = [map { $util->user_to_hash($_, $params, undef, 'mentors') }
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

# A bug history entry, as returned by history and the history field of get.
# Also used by the MyDashboard extension, as a class method.
sub changeset_to_hash {
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
    $change->{attachment_id} = $self->type('int', $attach_id)      if $attach_id;
    $change->{comment_id}    = $self->type('int', $comment->id)    if $comment;
    $change->{comment_count} = $self->type('int', $comment->count) if $comment;

    push(@{$item->{changes}}, $change);
  }

  return filter($filters, $item, $types, $prefix);
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
