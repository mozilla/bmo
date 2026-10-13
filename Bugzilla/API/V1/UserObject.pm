# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::UserObject;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Mojo::JSON qw(true);

use Bugzilla::API::V1::Util;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Group;
use Bugzilla::Hook;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::User::APIKey;
use Bugzilla::Util qw(detaint_natural mojo_user_agent trim);
use Bugzilla::WebService::Util
  qw(filter filter_wants merge_request_params params_to_objects translate);

use Digest::HMAC_SHA1 qw(hmac_sha1_hex);
use Try::Tiny;

use constant MAPPED_FIELDS =>
  {email => 'login', full_name => 'name', login_denied_text => 'disabledtext',};

use constant MAPPED_RETURNS => {
  login_name   => 'email',
  realname     => 'full_name',
  disabledtext => 'login_denied_text',
};

sub setup_routes {
  my ($class, $r) = @_;
  my $routes
    = $r->under('/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  $routes->get('/whoami')->to('V1::UserObject#whoami');
  $routes->options('/whoami')->to('V1::UserObject#options', allow => 'GET');

  # Must come before /user/#id_or_name, which would otherwise match it.
  $routes->get('/user/suggest')->to('V1::UserObject#suggest');
  $routes->options('/user/suggest')->to('V1::UserObject#options', allow => 'GET');

  # Likewise, and its OPTIONS route must not be answered by the /user/#id_or_name one.
  $routes->post('/user/offer_account_by_email')->to('V1::UserObject#offer_account_by_email');
  $routes->options('/user/offer_account_by_email')->to('V1::UserObject#options', allow => 'POST');

  $routes->get('/user')->to('V1::UserObject#get');
  $routes->post('/user')->to('V1::UserObject#create');
  $routes->get('/user/#id_or_name')->to('V1::UserObject#get');
  $routes->put('/user/#id_or_name')->to('V1::UserObject#update');

  $routes->options('/user')->to('V1::UserObject#options', allow => 'GET, POST');
  $routes->options('/user/#id_or_name')
    ->to('V1::UserObject#options', allow => 'GET, PUT');
}

sub options {
  my ($self) = @_;

  my $allow = $self->stash('allow');
  $self->res->headers->header('Allow'                        => $allow);
  $self->res->headers->header('Access-Control-Allow-Methods' => $allow);

  return $self->rendered(200);
}

# The webservice_user_get hook hands this controller to extensions as
# "webservice", and Review, UserProfile and TagNewUsers call ->type on it, as
# they did on the legacy JSON-RPC/REST server.
sub type {
  my ($self, $type, $value) = @_;
  return Bugzilla::API::V1::Util->type($type, $value);
}

# No login here, as in the legacy method (LOGIN_EXEMPT): this is how someone
# without an account asks for one.
sub offer_account_by_email {
  my ($self) = @_;

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  my $email = trim($params->{email})
    || return $self->code_error('param_required', {param => 'email'});

  Bugzilla->user->check_account_creation_enabled;
  Bugzilla->user->check_and_send_account_creation_confirmation($email);

  return $self->render(json => undef);
}

sub create {
  my ($self) = @_;

  # A logged-out user is in no group, so gets the same auth_failure as legacy.
  my $user = $self->bugzilla->login;
  $user->in_group('editusers')
    || return $self->user_error('auth_failure',
    {group => 'editusers', action => 'add', object => 'users'});

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  my $email = trim($params->{email})
    || return $self->code_error('param_required', {param => 'email'});

  my $new_user = Bugzilla::User->create({
    login_name    => $email,
    realname      => trim($params->{full_name}),
    cryptpassword => trim($params->{password}) || '*',
  });

  return $self->render(
    json   => {id => $self->type('int', $new_user->id)},
    status => 201
  );
}

sub suggest {
  my ($self) = @_;

  my $user = $self->bugzilla->login;

  my ($params, $error) = $self->_request_params;
  return $self->user_error($error) if $error;

  Bugzilla->switch_to_shadow_db();

  defined $params->{match}
    || return $self->code_error('params_required',
    {function => 'User.suggest', params => ['match']});

  $user->id || return $self->user_error('user_access_by_match_denied');

  # Not trimmed, as in the legacy method.
  my $s = $params->{match};
  return $self->render(json => {users => []}) if length($s) < 3;

  my $dbh    = Bugzilla->dbh;
  my @select = ('userid AS id');
  my $order  = 'last_activity_ts DESC';
  my $where;
  state $have_mysql = $dbh->isa('Bugzilla::DB::Mysql');

  if ($s =~ /^[:@](.+)$/s) {
    $where = $dbh->sql_prefix_match(nickname => $1);
  }
  elsif ($s =~ /@/) {
    $where = $dbh->sql_prefix_match(login_name => $s);
  }
  else {
    if ($have_mysql && ($s =~ /[[:space:]]/ || $s =~ /[^[:ascii:]]/)) {
      my $match = $dbh->sql_prefix_match_fulltext('realname', $s);
      push @select, "$match AS relevance";
      $order = 'relevance DESC';
      $where = $match;
    }
    elsif ($have_mysql && $s =~ /^[[:upper:]]/) {
      my $match = $dbh->sql_prefix_match_fulltext('realname', $s);
      $where = join ' OR ', $match, $dbh->sql_prefix_match(nickname => $s),
        $dbh->sql_prefix_match(login_name => $s);
    }
    else {
      $where = join ' OR ', $dbh->sql_prefix_match(nickname => $s),
        $dbh->sql_prefix_match(login_name => $s);
    }
  }
  $where = "($where) AND is_enabled = 1";

  my $results = $dbh->selectall_arrayref(
    "SELECT "
      . join(', ', @select)
      . " FROM profiles WHERE $where ORDER BY $order LIMIT 25",
    {Slice => {}}
  );
  my $user_objects = Bugzilla::User->new_from_list([map { $_->{id} } @$results]);

  my @user_data = map { {
    id        => $self->type('int',    $_->id),
    real_name => $self->type('string', $_->name),
    nick      => $self->type('string', $_->nick),
    name      => $self->type('email',  $_->login),
  } } @$user_objects;

  Bugzilla::Hook::process(
    'webservice_user_get',
    {
      webservice   => $self,
      params       => $params,
      user_data    => \@user_data,
      user_objects => $user_objects
    }
  );

  return $self->render(json => {users => \@user_data});
}

# Return user information by passing either user ids or login names or both
# together.
sub get {
  my ($self) = @_;

  my $api_user = $self->bugzilla->login;

  my ($params, $error)
    = $self->_request_params(qw(names ids match group_ids groups ldap_emails));
  return $self->user_error($error) if $error;

  if (defined(my $id_or_name = $self->stash('id_or_name'))) {
    $params->{$id_or_name =~ /^\d+$/ ? 'ids' : 'names'} = [$id_or_name];
  }

  Bugzilla->switch_to_shadow_db();

       defined($params->{names})
    || defined($params->{ids})
    || defined($params->{match})
    || defined($params->{ldap_emails})
    || return $self->code_error('params_required',
    {function => 'User.get', params => ['ids', 'names', 'match']});

  my (@user_objects, @faults);
  if ($params->{names}) {
    foreach my $name (@{$params->{names}}) {

      # If permissive mode, then we do not kill the whole
      # request if there is an error with user lookup.
      # We store the errors in 'faults' array.
      if ($params->{permissive}) {

        # In ERROR_MODE_DIE the error is thrown as its plain text message.
        my $old_error_mode = Bugzilla->error_mode;
        Bugzilla->error_mode(ERROR_MODE_DIE);
        my $user_obj = eval { Bugzilla::User->check({name => $name}) };
        my $message  = $@;
        Bugzilla->error_mode($old_error_mode);
        if (!$user_obj) {
          push @faults, {name => $name, error => true, message => trim("$message")};
          next;
        }
        push @user_objects, $user_obj;
      }
      else {
        push @user_objects, Bugzilla::User->check({name => $name});
      }
    }
  }

  # Allow users in mozilla-employee-confidential to search by ldap_email
  if ( $api_user->in_group('mozilla-employee-confidential')
    && $params->{ldap_emails})
  {
    foreach my $email (@{$params->{ldap_emails}}) {

 # There could be more than one match per ldap email if the user has multiple accounts
      my $user_ids
        = Bugzilla->dbh->selectcol_arrayref(
        'SELECT user_id FROM profile_mfa WHERE name = \'user\' AND value = ?',
        undef, $email);
      next if !@{$user_ids};
      foreach my $user_id (@{$user_ids}) {
        my $user_obj = Bugzilla::User->new($user_id);
        next if $user_obj->mfa ne 'Duo';
        push @user_objects, $user_obj;
      }
    }
  }
  elsif ($params->{ldap_emails}) {
    return $self->user_error('user_access_by_ldap_denied');
  }

  # start filtering to remove duplicate user ids
  my %unique_users = map { $_->id => $_ } @user_objects;
  @user_objects = values %unique_users;

  my @users;

  # If the user is not logged in: Return an error if they passed any user ids.
  # Otherwise, return a limited amount of information based on login names.
  if (!$api_user->id) {
    if ($params->{ids}) {
      return $self->user_error('user_access_by_id_denied');
    }
    if ($params->{match}) {
      return $self->user_error('user_access_by_match_denied');
    }
    my $in_group = _filter_users_by_group($api_user, \@user_objects, $params);
    @users = map {
      filter $params,
        {
        id        => $self->type('int',    $_->id),
        real_name => $self->type('string', $_->name),
        nick      => $self->type('string', $_->nick),
        name      => $self->type('email',  $_->login),
        }
    } @$in_group;

    return $self->render(json => {users => \@users, faults => \@faults});
  }

  my $obj_by_ids;
  $obj_by_ids = Bugzilla::User->new_from_list($params->{ids}) if $params->{ids};

  # obj_by_ids are only visible to the user if they can see
  # the otheruser, for non visible otheruser throw an error
  foreach my $obj (@$obj_by_ids) {
    if ($api_user->can_see_user($obj)) {
      if (!$unique_users{$obj->id}) {
        push(@user_objects, $obj);
        $unique_users{$obj->id} = $obj;
      }
    }
    else {
      return $self->user_error(
        'auth_failure',
        {
          reason => 'not_visible',
          action => 'access',
          object => 'user',
          userid => $obj->id
        }
      );
    }
  }

  # User Matching
  my $limit;
  if ($params->{limit}) {
    detaint_natural($params->{limit})
      || return $self->code_error('param_must_be_numeric',
      {function => 'User.match', param => 'limit'});
    $limit = $params->{limit};
  }
  my $exclude_disabled = $params->{'include_disabled'} ? 0 : 1;
  foreach my $match_string (@{$params->{'match'} || []}) {
    my $matched = Bugzilla::User::match($match_string, $limit, $exclude_disabled);
    foreach my $user_obj (@$matched) {
      if (!$unique_users{$user_obj->id}) {
        push @user_objects, $user_obj;
        $unique_users{$user_obj->id} = $user_obj;
      }
    }
  }

  my $in_group = _filter_users_by_group($api_user, \@user_objects, $params);
  foreach my $user_obj (@$in_group) {
    my $user_info = filter $params,
      {
      id             => $self->type('int',      $user_obj->id),
      real_name      => $self->type('string',   $user_obj->name),
      nick           => $self->type('string',   $user_obj->nick),
      name           => $self->type('email',    $user_obj->login),
      email          => $self->type('email',    $user_obj->email),
      can_login      => $self->type('boolean',  $user_obj->is_enabled ? 1 : 0),
      last_seen_date => $self->type('dateTime', $user_obj->last_seen_date),
      creation_time  => $self->type('dateTime', $user_obj->creation_ts),
      };

    if ($api_user->in_group('disableusers')) {
      if (filter_wants($params, 'email_enabled')) {
        $user_info->{email_enabled} = $self->type('boolean', $user_obj->email_enabled);
      }
      if (filter_wants($params, 'login_denied_text')) {
        $user_info->{login_denied_text}
          = $self->type('string', $user_obj->disabledtext);
      }
    }

    if ($api_user->id == $user_obj->id) {
      if (filter_wants($params, 'saved_searches')) {
        $user_info->{saved_searches}
          = [map { $self->_query_to_hash($_) } @{$user_obj->queries}];
      }
    }

    # If calling user is member of mozilla-employee-confidential,
    # return ldap_email value as well
    if ( $api_user->in_group('mozilla-employee-confidential')
      && $user_obj->ldap_email)
    {
      $user_info->{ldap_email} = $user_obj->ldap_email;
    }

    if (filter_wants($params, 'groups')) {
      if ( $api_user->id == $user_obj->id
        || $api_user->in_group('mozilla-employee-confidential'))
      {
        $user_info->{groups} = [map { $self->_group_to_hash($_) } @{$user_obj->groups}];
      }
      else {
        $user_info->{groups}
          = [map { $self->_group_to_hash($_) }
          grep { $api_user->in_group('editusers') || $api_user->can_bless($_->id) }
            @{$user_obj->groups}];
      }
    }

    push(@users, $user_info);
  }

  Bugzilla::Hook::process(
    'webservice_user_get',
    {
      webservice   => $self,
      params       => $params,
      user_data    => \@users,
      user_objects => $in_group,
    }
  );

  return $self->render(json => {users => \@users, faults => \@faults});
}

sub update {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # Reject access if there is no sense in continuing.
  $user->in_group('editusers')
    || return $self->user_error('auth_failure',
    {group => 'editusers', action => 'edit', object => 'users'});

  my ($params, $error) = $self->_request_params(qw(names ids));
  return $self->user_error($error) if $error;

  if (defined(my $id_or_name = $self->stash('id_or_name'))) {
    $params
      = $id_or_name =~ /^\d+$/
      ? {%$params, ids => [$id_or_name], names => undef}
      : {%$params, names => [$id_or_name], ids => undef};
  }

  defined($params->{names})
    || defined($params->{ids})
    || return $self->code_error('params_required',
    {function => 'User.update', params => ['ids', 'names']});

  my $user_objects = params_to_objects($params, 'Bugzilla::User');

  # Some accounts are protected from being edited by non-admins.
  foreach my $user_obj (@$user_objects) {
    $user_obj->check_can_be_edited();
  }

  # Drop the request-level keys that are not user fields and pass everything
  # else through, so set_all() still raises unknown_method on an unrecognized
  # field rather than silently ignoring it.
  my $values = translate($params, MAPPED_FIELDS);
  delete @$values{qw(ids names include_fields exclude_fields
    Bugzilla_api_key Bugzilla_api_token Bugzilla_login Bugzilla_password
    Bugzilla_token api_key token)};

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction();
  foreach my $user_obj (@$user_objects) {
    $user_obj->set_all($values);
  }

  my %changes;
  foreach my $user_obj (@$user_objects) {
    my $returned_changes = $user_obj->update();
    $changes{$user_obj->id} = translate($returned_changes, MAPPED_RETURNS);
  }
  $dbh->bz_commit_transaction();

  my @result;
  foreach my $user_obj (@$user_objects) {
    my %hash = (id => $self->type('int', $user_obj->id), changes => {},);

    foreach my $field (keys %{$changes{$user_obj->id}}) {
      my $change = $changes{$user_obj->id}->{$field};

      # We normalize undef to an empty string, so that the API
      # stays consistent for things that can become empty.
      $change->[0] = '' if !defined $change->[0];
      $change->[1] = '' if !defined $change->[1];

      # We also flatten arrays (used by groups and blessed_groups)
      $change->[0] = join(',', @{$change->[0]}) if ref $change->[0];
      $change->[1] = join(',', @{$change->[1]}) if ref $change->[1];

      $hash{changes}{$field} = {
        removed => $self->type('string', $change->[0]),
        added   => $self->type('string', $change->[1])
      };
    }

    push(@result, \%hash);
  }

  return $self->render(json => {users => \@result});
}

sub whoami {
  my ($self) = @_;

  my $user = $self->_user_from_phab_token;
  if ($user) {

    # bugzilla.login is not involved here, so refuse a disabled account the
    # way it does.
    $self->bugzilla->assert_account_usable($user);
  }
  else {
    $user = $self->bugzilla->login;
    $user->id
      || return $self->user_error($self->_api_key_error // 'login_required');
  }

  my ($params, $error) = $self->_request_params;
  return $self->user_error($error) if $error;

  # Generate a deterministic ID from the site-wide-secret and user-id.
  # This can be used for user tracking in other systems without the
  # ability to trace the ID back to a specific Bugzilla account.
  my $uuid = hmac_sha1_hex($user->id, Bugzilla->localconfig->site_wide_secret);

  return $self->render(
    json => filter(
      $params,
      {
        id         => $self->type('int',     $user->id),
        real_name  => $self->type('string',  $user->name),
        nick       => $self->type('string',  $user->nick),
        name       => $self->type('email',   $user->login),
        mfa_status => $self->type('boolean', !!$user->mfa),
        groups     => [map { $_->name } @{$user->groups}],
        uuid       => $self->type('string', 'bmo-who:' . $uuid),
      }
    )
  );
}

# Merged query-string and body params, with the given params plus
# include_fields/exclude_fields always returned as lists.
sub _request_params {
  my ($self, @list_params) = @_;
  push @list_params, qw(include_fields exclude_fields);

  my ($params, $error) = merge_request_params($self, \@list_params);
  return (undef, $error) if $error;

  # A JSON body is merged in as-is, so a single value there is not yet a list;
  # legacy validate() coerced it the same way.
  for my $field (@list_params) {
    $params->{$field} = [$params->{$field}]
      if defined $params->{$field} && !ref $params->{$field};
  }

  for my $field (qw(include_fields exclude_fields)) {
    $params->{$field} = [map { split(/[\s,]+/) } @{$params->{$field}}]
      if defined $params->{$field};
  }

  return ($params, undef);
}

# bugzilla.login treats an API key it refuses as no API key at all. Clients
# use whoami to validate a key, so say why it was refused, as the legacy login
# did (Bugzilla::Auth::Login::APIKey).
sub _api_key_error {
  my ($self) = @_;

  my $query = $self->req->query_params;
  my $api_key_text
    = $self->req->headers->header('X-Bugzilla-API-Key')
    || $query->param('Bugzilla_api_key')
    || $query->param('api_key');
  return undef if !$api_key_text;

  my $api_key = Bugzilla::User::APIKey->new({name => $api_key_text});
  return 'api_key_not_valid' if !$api_key;
  return 'api_key_not_valid'
    if $api_key->sticky
    && $api_key->last_used_ip
    && $api_key->last_used_ip ne $self->tx->remote_address;
  return $api_key->revoked ? 'api_key_revoked' : 'api_key_not_valid';
}

sub _user_from_phab_token {
  my ($self) = @_;

  # BMO - If a token is provided in the X-PHABRICATOR-TOKEN header, we use that
  # to request the associated email address from Phabricator via its
  # `user.whoami` endpoint.

  # only if PhabBugz is configure and X-PHABRICATOR-TOKEN is provided
  (my $phab_url = Bugzilla->params->{phabricator_base_uri}) =~ s{/$}{};
  my $phab_token = $self->req->headers->header('X-Phabricator-Token');
  return undef unless $phab_url && $phab_token;

  return try {

    # query phabricator's whoami endpoint
    my $ua = mojo_user_agent({request_timeout => 5});
    $ua->transactor->name('BMO user.whoami shim');
    my $res = $ua->get(
      "$phab_url/api/user.whoami" => form => {'api.token' => $phab_token});
    my $ph_whoami = $res->result->json;

    # treat any phabricator generated error as an invalid api-key
    if (my $error = $ph_whoami->{error_info}) {
      DEBUG("Phabricator user.whoami failed: $error");
      ThrowUserError('api_key_not_valid');
    }

    # load user from primaryEmail
    my $user = Bugzilla::User->new(
      {name => $ph_whoami->{result}->{primaryEmail}, cache => 1});
    if (!$user) {
      DEBUG("No Bugzilla user for Phabricator email: "
          . $ph_whoami->{result}->{primaryEmail});
      ThrowUserError('api_key_not_valid');
    }
    $user;
  }
  catch {
    WARN("Request to $phab_url failed: $_");
    ThrowUserError('api_key_not_valid');
  };
}

sub _filter_users_by_group {
  my ($api_user, $users, $params) = @_;
  my ($group_ids, $group_names) = @$params{qw(group_ids groups)};

  # If no groups are specified, we return all users.
  return $users if (!$group_ids and !$group_names);

  my @groups = map { Bugzilla::Group->check({id => $_}) } @{$group_ids || []};

  if ($group_names) {
    foreach my $name (@$group_names) {
      my $group
        = Bugzilla::Group->check({name => $name, _error => 'invalid_group_name'});
      $api_user->in_group($group)
        || ThrowUserError('invalid_group_name', {name => $name});
      push(@groups, $group);
    }
  }

  my @in_group = grep {
    my $user = $_;
    grep { $user->in_group($_) } @groups
  } @$users;
  return \@in_group;
}

sub _group_to_hash {
  my ($self, $group) = @_;
  return {
    id          => $self->type('int',    $group->id),
    name        => $self->type('string', $group->name),
    description => $self->type('string', $group->description),
  };
}

sub _query_to_hash {
  my ($self, $query) = @_;
  return {
    id   => $self->type('int',    $query->id),
    name => $self->type('string', $query->name),
    url  => $self->type('string', $query->url),
  };
}

1;
