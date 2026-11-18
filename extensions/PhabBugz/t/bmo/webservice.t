#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The /rest/phabbugz routes, called in-process so the fake Conduit answers
# their Phabricator requests: bug_revisions (with edge.search for stacks),
# user, and the permission checks used by Phabricator.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Config     qw(SetParam);
use Bugzilla::Test::Util qw(issue_api_key);
use Test::Mojo;
use Test::More;

use Bugzilla::Extension::PhabBugz::Util qw(create_revision_attachment);
use PhabTest::Conduit                   qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $t       = Test::Mojo->new('Bugzilla::App');

# Each request starts with a clean request cache, so put the fake Conduit's
# params back (and any test override) before the action runs.
my %params;
$t->app->hook(
  around_action => sub {
    my ($next) = @_;
    $conduit->apply_params;
    SetParam($_, $params{$_}) foreach keys %params;
    return $next->();
  }
);

my %key;

sub auth {
  my ($user) = @_;
  $key{$user->login} //= issue_api_key($user->login)->api_key;
  return {'X-Bugzilla-API-Key' => $key{$user->login}};
}

# GET a route as $user and return the decoded response.
sub api {
  my ($user, $path) = @_;
  $t->get_ok("/rest/phabbugz/$path" => auth($user));
  return $t->tx->res->json;
}

# Check that GET $path as $user fails with a message matching $re.
sub api_error {
  my ($user, $path, $re, $name) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $json = api($user, $path);
  ok($json->{error}, "$name: error");
  like($json->{message}, $re, "$name: message");
}

my $author        = $env->bmo_user('author');
my $author_phab   = $env->link_user($author, username => 'phabtest-author');
my $reviewer      = $env->bmo_user('reviewer');
my $reviewer_phab = $env->link_user($reviewer, username => 'phabtest-reviewer');
my $repo
  = $conduit->add_repository(repository_obj(callsign => 'MOZILLACENTRAL'));

my $bug       = $env->bug;
my $other_bug = $env->bug;

my $parent = $conduit->add_revision(revision_obj(
  title           => 'Parent revision',
  status          => 'accepted',
  bug_id          => $bug->id,
  author_phid     => $author_phab->{phid},
  repository_phid => $repo->{phid},
  reviewers       => [{phid => $reviewer_phab->{phid}, status => 'accepted'}],
));
my $child = $conduit->add_revision(revision_obj(
  title       => 'Secret child',
  status      => 'needs-review',
  bug_id      => $bug->id,
  author_phid => $author_phab->{phid},
  view_policy => 'PHID-PLCY-secret',
  reviewers   => [{phid => $reviewer_phab->{phid}, status => 'blocking'}],
));
my $moved = $conduit->add_revision(revision_obj(
  title       => 'Moved to another bug',
  bug_id      => $other_bug->id,
  author_phid => $author_phab->{phid},
));
$conduit->add_edge($parent->{phid}, $child->{phid});
$conduit->add_edge($parent->{phid}, 'PHID-DREV-notonthisbug');

my ($timestamp) = Bugzilla->dbh->selectrow_array('SELECT NOW()');
foreach my $raw ($parent, $child, $moved) {
  create_revision_attachment(
    Bugzilla::Bug->new($bug->id),
    $conduit->load_revision($raw),
    $timestamp, $author
  );
}

# bug_revisions
{
  $env->fresh_request;
  $conduit->reset_calls;
  my $result = api($author, 'bug_revisions/' . $bug->id);

  my ($search) = $conduit->calls('differential.revision.search');
  is_deeply(
    $search,
    {
      attachments =>
        {projects => 1, reviewers => 1, subscribers => 1, 'reviewers-extra' => 1,},
      constraints => {ids => [$parent->{id}, $child->{id}, $moved->{id}]},
      order       => 'newest',
    },
    'differential.revision.search for the attached revision ids'
  );
  is_deeply(
    [$conduit->calls('edge.search')],
    [{
      sourcePHIDs => [map { $_->{phid} } $moved, $child, $parent],
      types       => ['revision.child'],
    }],
    'edge.search for stack children'
  );

  is_deeply(
    $result,
    {
      revisions => [
        {
          id          => "D$parent->{id}",
          sortkey     => $parent->{id},
          status      => 'accepted',
          long_status => 'Accepted',
          title       => 'Parent revision',
          call_sign   => 'MOZILLACENTRAL',
          children    => ["D$child->{id}"],
          reviews     => [
            {user => 'phabtest-reviewer', status => 'accepted', long_status => 'Accepted'},
          ],
        },
        {
          id          => "D$child->{id}",
          sortkey     => $child->{id},
          status      => 'needs-review',
          long_status => 'Needs Review',
          title       => '(secured)',
          call_sign   => '(secured)',
          children    => [],
          reviews     => [
            {
              user        => 'phabtest-reviewer',
              status      => 'blocking',
              long_status => 'Blocking Review'
            },
          ],
        },
      ],
    },
    'revisions sorted by id, moved revision skipped, private title hidden'
  );
}

# bug_revisions: malformed and failed responses
{
  $env->fresh_request;
  $conduit->queue('differential.revision.search' => {data => 'not a list'});
  api_error(
    $author,
    'bug_revisions/' . $bug->id,
    qr/Phabricator API Error|Reason:/,
    'malformed search result'
  );

  $conduit->queue('edge.search' => http_error(500));
  api_error(
    $author,
    'bug_revisions/' . $bug->id,
    qr/Phabricator API Error|Reason:/,
    'edge.search failure'
  );

  $env->fresh_request;
  my $empty = $env->bug;
  $conduit->reset_calls;
  is_deeply(
    api($author, 'bug_revisions/' . $empty->id),
    {revisions => []},
    'bug without revisions'
  );
}

# user
{
  $env->fresh_request;
  $conduit->reset_calls;
  my $result = api($author, 'user/' . $author->id);
  is_deeply(
    [$conduit->calls('bmoexternalaccount.search')],
    [{accountids => [$author->id]}],
    'bmoexternalaccount.search params'
  );
  is_deeply(
    [$conduit->calls('user.query')],
    [{phids => [$author_phab->{phid}]}],
    'user.query params'
  );

  (my $base = $conduit->base_uri) =~ s{/$}{};
  is_deeply(
    $result,
    {
      user => {
        phid         => $author_phab->{phid},
        userName     => 'phabtest-author',
        realName     => $author->name,
        userURL      => "$base/p/phabtest-author/",
        revisionsURL => "$base/differential/?responsiblePHIDs%5B0%5D="
          . $author_phab->{phid}
          . '&statuses%5B0%5D=open()&order=newest&bucket=action',
      },
    },
    'user details and Phabricator URLs'
  );

  $env->fresh_request;
  my $stranger = $env->bmo_user('no-phab-account');
  $conduit->reset_calls;
  is_deeply(api($author, 'user/' . $stranger->id), {}, 'unknown user returns {}');
  is($conduit->call_count('user.query'), 0, 'no user.query without a PHID');

  $conduit->queue('user.query' => []);
  is_deeply(api($author, 'user/' . $author->id), {},
    'user.query without results');
}

# Permission checks are only for phab-bot
{
  $env->fresh_request;
  my $group   = $env->bug_group('ws');
  my $private = $env->bug(groups => [$group]);
  my $bot     = $env->phab_bot;
  my $uid     = $author->id;

  is_deeply(
    api($bot, 'check_bug/' . $bug->id . "/$uid"),
    {result => 1},
    'user can see a public bug'
  );
  is_deeply(
    api($bot, 'check_bug/' . $private->id . "/$uid"),
    {result => 0},
    'user cannot see a private bug'
  );
  is_deeply(
    api($bot, "check_enter_bug/Firefox/$uid"),
    {result => 1},
    'user can file bugs in Firefox'
  );

  is_deeply(
    api($bot, "check_enter_bug/No.Such%20Product/$uid"),
    {result => 0},
    'product names may contain dots and spaces'
  );

  # The routes require both values, so only a 0 can be missing.
  api_error(
    $bot,
    'check_bug/' . $bug->id . '/0',
    qr/must be provided/,
    'user_id is required'
  );
  api_error($bot, "check_bug/0/$uid", qr/must be provided/, 'bug_id is required');

  api_error(
    $author,
    'check_bug/' . $bug->id . "/$uid",
    qr/do not have permission/,
    'only phab-bot may call check_bug'
  );
  api_error(
    $author,
    "check_enter_bug/Firefox/$uid",
    qr/do not have permission/,
    'only phab-bot may call check_enter_bug'
  );

  $t->get_ok('/rest/phabbugz/bug_revisions/' . $bug->id)
    ->status_is(401, 'bug_revisions needs a login');
}

# Everything is refused while the integration is disabled
{
  my $bot = $env->phab_bot;
  local $params{phabricator_enabled} = 0;
  $conduit->reset_calls;
  api_error(
    $author,
    'bug_revisions/' . $bug->id,
    qr/is not enabled/,
    'bug_revisions disabled'
  );
  api_error($author, 'user/' . $author->id, qr/is not enabled/, 'user disabled');
  api_error(
    $bot,
    'check_bug/' . $bug->id . '/' . $author->id,
    qr/is not enabled/,
    'check_bug disabled'
  );
  is($conduit->call_count, 0, 'no Conduit calls while disabled');
}

$env->fresh_request;
$env->finish;
done_testing;
