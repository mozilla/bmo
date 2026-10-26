# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# An in-process fake Phabricator Conduit server.
#
# PhabBugz::Util::request() sends every Conduit call through
# Mojo::UserAgent->post. This module overrides that method, decodes the
# `params` form field, records the call and answers it from an in-memory
# directory of users, projects, revisions, repositories, policies, feed
# stories, transactions and edges. Posts to any other URL go to the real
# Mojo::UserAgent->post, so other extensions' HTTP calls are not mistaken
# for Conduit calls.
#
# Usage:
#
#   my $conduit = PhabTest::Conduit->new;
#   my $user    = $conduit->add_user(user_obj(...));
#   $conduit->on('user.search' => sub { my ($params) = @_; ... });
#   $conduit->queue('feed.query_id' => conduit_error('ERR', 'boom'));
#   my @calls = $conduit->calls('differential.revision.edit');
#
# Precedence for answering a call: queued replies, then `on` handlers, then
# the built-in directory handlers. A reply is either a hashref (the Conduit
# `result` payload) or one of the failure objects built by conduit_error(),
# http_error(), network_error(), invalid_json() or raw_reply().

package PhabTest::Conduit;

use 5.10.1;
use strict;
use warnings;

use base qw(Exporter);
our @EXPORT_OK = qw(
  conduit_error
  cursor_invalid
  http_error
  invalid_json
  network_error
  raw_reply
  throws_error
  with_typed_errors
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use Bugzilla;
use Bugzilla::Config qw(SetParam);
use Bugzilla::Extension::PhabBugz::Revision;
use List::Util       qw(first);
use Mojo::JSON       qw(decode_json encode_json);
use Mojo::Transaction::HTTP;
use Mojo::UserAgent;
use Scalar::Util       qw(blessed weaken);
use Scope::Guard;
use Storable           qw(dclone);
use Test2::Tools::Mock qw(mock);
use Test::More         ();
use Try::Tiny;

use PhabTest::Fixtures qw(:all);

use constant DEFAULT_BASE_URI => 'https://phabricator.test.example.com/';
use constant DEFAULT_API_KEY  => 'api-phabtestfakeconduitkey000';

sub new {
  my ($class) = @_;
  my $self = bless {
    base_uri   => DEFAULT_BASE_URI,
    api_key    => DEFAULT_API_KEY,
    page_size  => 100,
    handlers   => {},
    queues     => {},
    calls      => [],
    unexpected => [],
    bad_auth   => [],
    users      => [],
    projects   => [],
    revisions  => [],
    repos      => [],
    policies   => [],
    stories    => [],
    seen_story => {1 => 1},
    xactions   => {},
    edges      => [],
  }, $class;

  $self->apply_params;

  my $weak_self = $self;
  weaken($weak_self);
  my $orig_post = Mojo::UserAgent->can('post');
  $self->{mock} = mock 'Mojo::UserAgent' => (
    override => [
      post => sub {
        my ($ua, $url, @form) = @_;
        return $orig_post->(@_) unless $weak_self && $weak_self->_is_conduit_url($url);
        return $weak_self->_dispatch($url, @form);
      },
    ],
  );

  return $self;
}

# Set the PhabBugz params in memory only. They live in the request cache, so
# call this again after anything that clears it (Bugzilla->_cleanup,
# Bugzilla->clear_request_cache).
sub apply_params {
  my ($self) = @_;
  SetParam('phabricator_enabled',  1);
  SetParam('phabricator_base_uri', $self->{base_uri});
  SetParam('phabricator_api_key',  $self->{api_key});
  return $self;
}

sub base_uri {
  my ($self) = @_;
  return $self->{base_uri};
}

sub api_key {
  my ($self) = @_;
  return $self->{api_key};
}

# Set the page size until the returned guard goes out of scope, even if the
# block dies:  my $guard = $conduit->local_page_size(2);
sub local_page_size {
  my ($self, $size) = @_;
  my $old = $self->{page_size};
  $self->{page_size} = $size;
  return Scope::Guard->new(sub { $self->{page_size} = $old });
}

#################
# Configuration #
#################

sub on {
  my ($self, $method, $reply) = @_;
  $self->{handlers}{$method} = $reply;
  return $self;
}

sub off {
  my ($self, $method) = @_;
  delete $self->{handlers}{$method};
  return $self;
}

sub queue {
  my ($self, $method, @replies) = @_;
  push @{$self->{queues}{$method}}, @replies;
  return $self;
}

sub add_user {
  my ($self, $obj) = @_;
  return $self->_add(users => $obj);
}

sub add_project {
  my ($self, $obj) = @_;
  return $self->_add(projects => $obj);
}

sub add_revision {
  my ($self, $obj) = @_;
  return $self->_add(revisions => $obj);
}

# Add $raw (a revision_obj) to the directory if it is not there yet and load
# it as a PhabBugz::Revision.
sub load_revision {
  my ($self, $raw) = @_;
  $self->add_revision($raw) unless grep { $_ == $raw } @{$self->{revisions}};
  return Bugzilla::Extension::PhabBugz::Revision->new_from_query({
    phids => [$raw->{phid}]
  });
}

sub add_repository {
  my ($self, $obj) = @_;
  return $self->_add(repos => $obj);
}

sub add_policy {
  my ($self, $obj) = @_;
  return $self->_add(policies => $obj);
}

sub add_story {
  my ($self, $obj) = @_;
  return $self->_add(stories => $obj);
}

# Record that a feed story with this id exists in Phabricator but is not
# served (it was processed before the test). feed.query_id accepts it as an
# `after` cursor. Story 1, new_stories' default cursor, is always known.
sub add_seen_story {
  my ($self, $id) = @_;
  $self->{seen_story}{$id} = 1;
  return $self;
}

sub _add {
  my ($self, $kind, $obj) = @_;
  push @{$self->{$kind}}, $obj;
  return $obj;
}

sub add_transaction {
  my ($self, $object_phid, $xact) = @_;
  push @{$self->{xactions}{$object_phid}}, $xact;
  return $xact;
}

sub add_edge {
  my ($self, @edge) = @_;
  push @{$self->{edges}}, edge_obj(@edge);
  return $self;
}

sub find_project {
  my ($self, $key, $value) = @_;
  return
    first { $key eq 'name' ? $_->{fields}{name} eq $value : $_->{$key} eq $value }
    @{$self->{projects}};
}

###############
# Inspection  #
###############

# Decoded params (without the __conduit__ token) of every call to $method,
# oldest first. Without a method, every call as
# {method => ..., url => ..., params => ...}.
sub calls {
  my ($self, $method) = @_;
  return @{$self->{calls}} unless defined $method;
  return map { $_->{params} } grep { $_->{method} eq $method } @{$self->{calls}};
}

sub call_count {
  my ($self, $method) = @_;
  return scalar $self->calls($method);
}

sub reset_calls {
  my ($self) = @_;
  $self->{calls} = [];
  return $self;
}

# Transactions sent by *.edit calls for one object, flattened in order.
sub transactions_for {
  my ($self, $phid, $method) = @_;
  $method //= 'differential.revision.edit';
  return
    map { @{$_->{transactions}} }
    grep { ($_->{objectIdentifier} // '') eq $phid } $self->calls($method);
}

sub unexpected {
  my ($self) = @_;
  return $self->{unexpected};
}

# Every test file should end with this: no unhandled methods, and every call
# carried the configured API token to the expected URL.
sub verify {
  my ($self, $name) = @_;
  $name //= 'fake Conduit';
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  Test::More::is_deeply($self->{unexpected}, [],
    "$name: no calls to unhandled Conduit methods");
  Test::More::is_deeply($self->{bad_auth}, [],
    "$name: every call used the API token and /api/<method> URL");
}

############
# Replies  #
############

sub conduit_error {
  my ($code, $info) = @_;
  return bless {type => 'conduit', code => $code, info => $info},
    'PhabTest::Conduit::Reply';
}

# The error feed.query_id gives when `after` names a story id that is gone.
sub cursor_invalid {
  my ($id) = @_;
  return conduit_error('ERR-CONDUIT-CORE',
    "The value \"$id\" does not identify a valid object in query.");
}

sub http_error {
  my ($code, $body) = @_;
  return bless {type => 'http', code => $code, body => $body // ''},
    'PhabTest::Conduit::Reply';
}

# What Mojo::UserAgent does for connection refused, DNS failures, TLS errors
# and timeouts: the transaction has an error without an HTTP code, so
# $tx->result croaks.
sub network_error {
  my ($message) = @_;
  return bless {type => 'network', message => $message // 'Connection refused'},
    'PhabTest::Conduit::Reply';
}

sub invalid_json {
  return raw_reply('<html><body>502 Bad Gateway</body></html>', 'text/html');
}

sub raw_reply {
  my ($body, $content_type) = @_;
  return bless {type => 'raw', body => $body, content_type => $content_type},
    'PhabTest::Conduit::Reply';
}

# Run $code and check that it throws a Bugzilla error of $type, for example
# 'bugzilla.code.phabricator_api_error'. Returns the exception (or undef).
sub throws_error {
  my ($code, $type, $name) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $error;
  try { with_typed_errors($code) } catch { $error = $_ };
  if (!defined $error) {
    Test::More::fail("$name (no exception thrown)");
    return undef;
  }
  my $got = blessed $error && $error->can('type') ? $error->type : "$error";
  Test::More::is($got, $type, $name);
  return $error;
}

# Run $code with Bugzilla errors thrown as Template::Exception objects that
# have a ->type, instead of rendered error pages. Returns what $code returns.
sub with_typed_errors {
  my ($code) = @_;
  local $Bugzilla::Template::is_processing = 1;
  return $code->();
}

###############
# Dispatching #
###############

sub _dispatch {
  my ($self, $url, $form_type, $form) = @_;

  my $params = {};
  try {
    $params = decode_json($form->{params});
  }
  catch {
    push @{$self->{bad_auth}}, "undecodable params for $url";
  };

  my $token = delete($params->{__conduit__}) // {};

  # Accept <base>/api/<method> with one or more slashes before "api", so the
  # fake does not depend on whether base_uri ends in a slash.
  my ($method) = $url =~ m{^\Q${\ $self->_base}\E/+api/([\w.]+)$};
  if (!$method || ($token->{token} // '') ne $self->{api_key}) {
    push @{$self->{bad_auth}}, $url;
  }
  ($method) = $url =~ m{/api/([\w.]+)$} unless $method;
  $method //= $url;

  push @{$self->{calls}},
    {method => $method, url => $url, params => dclone($params)};

  my $reply;
  if (@{$self->{queues}{$method} // []}) {
    $reply = shift @{$self->{queues}{$method}};
  }
  elsif (my $handler = $self->{handlers}{$method}) {
    $reply = ref $handler eq 'CODE' ? $handler->($params, $self) : $handler;
  }
  else {
    $reply = $self->default_reply($method, $params);
  }

  return _transaction($reply);
}

sub _base {
  my ($self) = @_;
  return $self->{base_uri} =~ s{/+$}{}r;
}

sub _is_conduit_url {
  my ($self, $url) = @_;
  return index("$url", $self->_base . '/') == 0;
}

# The built-in directory answer for $method. `on` handlers can call this to
# fail only some requests and pass the rest through.
sub default_reply {
  my ($self, $method, $params) = @_;
  if (my $builtin = $self->can('reply_' . ($method =~ s/\./_/gr))) {
    return $self->$builtin($params);
  }
  push @{$self->{unexpected}}, $method;
  return conduit_error('ERR-CONDUIT-CALL',
    "Conduit method \"$method\" does not exist.");
}

sub _transaction {
  my ($reply) = @_;
  my $tx      = Mojo::Transaction::HTTP->new;
  my $res     = $tx->res;

  if (blessed $reply && $reply->isa('PhabTest::Conduit::Reply')) {
    if ($reply->{type} eq 'network') {
      $res->error({message => $reply->{message}});
      return $tx;
    }
    if ($reply->{type} eq 'http') {
      $res->code($reply->{code});
      $res->message($res->default_message);
      $res->headers->content_type('text/html');
      $res->body($reply->{body});
      return $tx;
    }
    if ($reply->{type} eq 'raw') {
      $res->code(200);
      $res->headers->content_type($reply->{content_type} // 'application/json');
      $res->body($reply->{body});
      return $tx;
    }
    $res->code(200);
    $res->headers->content_type('application/json');
    $res->body(encode_json(
      {result => undef, error_code => $reply->{code}, error_info => $reply->{info}}
    ));
    return $tx;
  }

  $res->code(200);
  $res->headers->content_type('application/json');
  $res->body(
    encode_json({result => $reply, error_code => undef, error_info => undef}));
  return $tx;
}

#######################################
# Built-in replies (fake directory)   #
#######################################

# Return one page of @items (sorted by id descending, the Conduit default
# order) honouring the `after` cursor and the configured page size.
sub _page {
  my ($self, $params, @items) = @_;
  @items = reverse sort { $a->{id} <=> $b->{id} } @items;
  if (my $after = $params->{after}) {
    @items = grep { $_->{id} < $after } @items;
  }
  my $limit = $self->{page_size};
  my $more  = @items > $limit;
  @items = @items[0 .. $limit - 1] if $more;
  return search_result(
    [map { dclone($_) } @items],
    limit => $limit,
    after => ($more ? $items[-1]{id} : undef)
  );
}

sub _filter {
  my ($constraints, @items) = @_;
  if (my $phids = $constraints->{phids}) {
    my %want = map { $_ => 1 } @$phids;
    @items = grep { $want{$_->{phid}} } @items;
  }
  if (my $ids = $constraints->{ids}) {
    my %want = map { $_ => 1 } @$ids;
    @items = grep { $want{$_->{id}} } @items;
  }
  return @items;
}

sub _bmo_id_of {
  my ($user)   = @_;
  my $accounts = $user->{attachments}{'external-accounts'}{'external-accounts'};
  my $bmo      = first { $_->{type} eq 'bmo' } @{$accounts // []};
  return $bmo ? $bmo->{id} : undef;
}

sub reply_user_search {
  my ($self, $params) = @_;
  my @users = _filter($params->{constraints} // {}, @{$self->{users}});

  # PhabBugz::Feed::new_users pages forward with `before`: Conduit returns
  # the page of users created right after that id.
  if (my $before = $params->{before}) {
    my @newer = sort { $a->{id} <=> $b->{id} } grep { $_->{id} > $before } @users;
    @newer = @newer[0 .. $self->{page_size} - 1] if @newer > $self->{page_size};
    return search_result([map { dclone($_) } reverse @newer],
      limit => $self->{page_size});
  }

  return $self->_page($params, @users);
}

# bugzilla.account.search items ({id => BMO id as a string, phid => user
# PHID}) for the users linked to @$ids.
sub _accounts_by_bmo_id {
  my ($self, $ids) = @_;
  my %want = map { $_ => 1 } @{$ids // []};
  return [
    map { {id => "$_->[0]", phid => $_->[1]{phid}} }
    grep { defined $_->[0] && $want{$_->[0]} }
    map { [_bmo_id_of($_), $_] } @{$self->{users}}
  ];
}

sub reply_bugzilla_account_search {
  my ($self, $params) = @_;
  return $self->_accounts_by_bmo_id($params->{ids});
}

sub reply_bmoexternalaccount_search {
  my ($self, $params) = @_;
  return $self->_accounts_by_bmo_id($params->{accountids});
}

# The legacy user.query method returns a flat list.
sub reply_user_query {
  my ($self, $params) = @_;
  return [
    map {
      +{
        phid     => $_->{phid},
        userName => $_->{fields}{username},
        realName => $_->{fields}{realName},
        image    => $self->_base . '/file/data/profile.png',
        uri      => $self->_base . "/p/$_->{fields}{username}/",
        roles    => $_->{fields}{roles},
      }
    } _filter({phids => $params->{phids} // []}, @{$self->{users}})
  ];
}

sub reply_user_edit {
  my ($self, $params) = @_;
  return edit_result($params->{objectIdentifier});
}

# Conduit tokenizes the `name` constraint, so a search for "bmo-foo" also
# returns "bmo-foo-bar". PhabBugz::Project::new_from_query has to pick the
# exact match; this fake behaves the same way.
sub reply_project_search {
  my ($self, $params) = @_;
  my $constraints = $params->{constraints} // {};
  my @projects    = _filter($constraints, @{$self->{projects}});
  if (defined(my $name = $constraints->{name})) {
    @projects = grep { index($_->{fields}{name}, $name) >= 0 } @projects;
  }
  return $self->_page($params, @projects);
}

sub reply_project_edit {
  my ($self, $params) = @_;
  my $project;

  if (my $phid = $params->{objectIdentifier}) {
    $project = $self->find_project(phid => $phid);
    return conduit_error('ERR-CONDUIT-CORE',
      "Monogram, PHID, or ID \"$phid\" does not identify a valid object.")
      unless $project;
  }
  else {
    $project = $self->add_project(project_obj(name => 'phabtest-unnamed'));
  }

  my $fields  = $project->{fields};
  my $members = $project->{attachments}{members}{members};
  foreach my $xact (@{$params->{transactions} // []}) {
    my ($type, $value) = @$xact{qw(type value)};
    if ($type eq 'name') { $fields->{name} = $fields->{slug} = $value }
    elsif ($type eq 'description') { $fields->{description} = $value }
    elsif ($type =~ /^(view|edit|join)$/) { $fields->{policy}{$type} = $value }
    elsif ($type eq 'members.set') {
      @$members = map { {phid => $_} } @$value;
    }
    elsif ($type eq 'members.add') {
      push @$members, map { {phid => $_} } @$value;
    }
    elsif ($type eq 'members.remove') {
      my %drop = map { $_ => 1 } @$value;
      @$members = grep { !$drop{$_->{phid}} } @$members;
    }
  }

  return edit_result($project->{phid}, $project->{id});
}

sub reply_differential_revision_search {
  my ($self, $params) = @_;
  my $result = $self->_page($params,
    _filter($params->{constraints} // {}, @{$self->{revisions}}));

  # Like Conduit, only return the attachments the caller asked for
  my $wanted = $params->{attachments} // {};
  foreach my $revision (@{$result->{data}}) {
    my $attachments = $revision->{attachments};
    delete @$attachments{grep { !$wanted->{$_} } keys %$attachments};
  }
  return $result;
}

sub reply_differential_revision_edit {
  my ($self, $params) = @_;
  my $phid     = $params->{objectIdentifier};
  my $revision = first { $_->{phid} eq $phid } @{$self->{revisions}};
  return conduit_error('ERR-CONDUIT-CORE',
    "Monogram, PHID, or ID \"$phid\" does not identify a valid object.")
    unless $revision;
  return edit_result($phid, $revision->{id});
}

sub reply_diffusion_repository_search {
  my ($self, $params) = @_;
  return $self->_page($params,
    _filter($params->{constraints} // {}, @{$self->{repos}}));
}

sub reply_policy_query {
  my ($self, $params) = @_;
  my %want = map { $_ => 1 } @{$params->{phids} // []};
  return search_result(
    [map { dclone($_) } grep { $want{$_->{phid}} } @{$self->{policies}}]);
}

# Rule classes the fake policy.create accepts.
use constant POLICY_RULES => {
  map { $_ => 1 } qw(
    PhabricatorAdministratorsPolicyRule
    PhabricatorDifferentialReviewersPolicyRule
    PhabricatorProjectsAllPolicyRule
    PhabricatorProjectsPolicyRule
    PhabricatorSubscriptionsSubscribersPolicyRule
    PhabricatorUsersPolicyRule
  )
};

# policy.create (a BMO-specific Conduit method, CreatePolicyConduitAPIMethod
# in mozilla-conduit/phabricator-private) checks each rule and stores it in
# the shape policy.query returns: `action`, `rule` and `value` always set.
# Like the real method, a rule with a bad action or a missing or unknown
# rule class is an ERR-INVALID-PARAMETER error. It is not repaired.
sub reply_policy_create {
  my ($self, $params) = @_;
  my @rules;
  foreach my $rule (@{$params->{policy} // []}) {
    my $action = $rule->{action} // '';
    return conduit_error('ERR-INVALID-PARAMETER', "Invalid action '$action'!")
      unless $action eq 'allow' || $action eq 'deny';
    my $class = $rule->{rule} // '';
    return conduit_error('ERR-INVALID-PARAMETER', "Invalid rule class '$class'!")
      unless POLICY_RULES->{$class};
    my $value = $rule->{value};
    push @rules,
      {
      action => $action,
      rule   => $class,
      value  => (ref $value ? dclone($value) : defined $value ? [$value] : undef),
      };
  }
  my $policy
    = $self->add_policy(policy_obj(default => $params->{default}, rules => \@rules));
  return {phid => $policy->{phid}};
}

# Like feed.query_id, `after` must be the id of an existing story, otherwise
# the call fails and Feed::new_stories retries with the next id. Returns the
# oldest page_size stories after it (newest first), so the rest come back on
# the next run.
sub reply_feed_query_id {
  my ($self, $params) = @_;
  my $after = $params->{after} // 0;
  return cursor_invalid($after)
    unless $self->{seen_story}{$after}
    || first { $_->{id} == $after } @{$self->{stories}};

  my @stories = sort { $a->{id} <=> $b->{id} }
    grep { $_->{id} > $after } @{$self->{stories}};
  splice(@stories, $self->{page_size}) if @stories > $self->{page_size};
  return search_result([map { dclone($_) } reverse @stories]);
}

sub reply_transaction_search {
  my ($self, $params) = @_;
  return search_result($self->{xactions}{$params->{objectIdentifier}} // []);
}

sub reply_edge_search {
  my ($self, $params) = @_;
  my %source = map { $_ => 1 } @{$params->{sourcePHIDs} // []};
  my %types  = map { $_ => 1 } @{$params->{types}       // []};
  return search_result([
    grep { $source{$_->{sourcePHID}} && $types{$_->{edgeType}} } @{$self->{edges}}
  ]);
}

1;
