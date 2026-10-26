#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::WebService methods, called in-process so the fake Conduit
# answers their Phabricator requests: bug_revisions (with edge.search for
# stacks), user, and the permission checks used by Phabricator.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Config qw(SetParam);
use Test::More;

use Bugzilla::Extension::PhabBugz::Util qw(create_revision_attachment);
use Bugzilla::Extension::PhabBugz::WebService;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $ws      = bless {}, 'Bugzilla::Extension::PhabBugz::WebService';

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
  create_revision_attachment(Bugzilla::Bug->new($bug->id),
    $conduit->load_revision($raw), $timestamp, $author);
}

# bug_revisions
{
  $env->fresh_request;
  $conduit->reset_calls;
  my $result = $ws->bug_revisions({bug_id => $bug->id});

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
  throws_error(
    sub { $ws->bug_revisions({bug_id => $bug->id}) },
    'bugzilla.code.phabricator_api_error',
    'malformed search result'
  );

  $conduit->queue('edge.search' => http_error(500));
  throws_error(
    sub { $ws->bug_revisions({bug_id => $bug->id}) },
    'bugzilla.code.phabricator_api_error',
    'edge.search failure'
  );

  my $empty = $env->bug;
  $conduit->reset_calls;
  is_deeply(
    $ws->bug_revisions({bug_id => $empty->id}),
    {revisions => []},
    'bug without revisions'
  );
}

# user
{
  $env->fresh_request;
  $conduit->reset_calls;
  my $result = $ws->user({user_id => $author->id});
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

  my $stranger = $env->bmo_user('no-phab-account');
  $conduit->reset_calls;
  is_deeply($ws->user({user_id => $stranger->id}), {}, 'unknown user returns {}');
  is($conduit->call_count('user.query'), 0, 'no user.query without a PHID');

  $conduit->queue('user.query' => []);
  is_deeply($ws->user({user_id => $author->id}), {},
    'user.query without results');
}

# Permission checks are only for phab-bot
{
  my $group   = $env->bug_group('ws');
  my $private = $env->bug(groups => [$group]);

  $env->fresh_request($env->phab_bot);
  is_deeply(
    $ws->check_user_permission_for_bug({bug_id => $bug->id, user_id => $author->id
    }),
    {result => 1},
    'user can see a public bug'
  );
  is_deeply(
    $ws->check_user_permission_for_bug({
      bug_id => $private->id, user_id => $author->id
    }),
    {result => 0},
    'user cannot see a private bug'
  );
  is_deeply(
    $ws->check_user_enter_bug_permission({
      product => 'Firefox', user_id => $author->id
    }),
    {result => 1},
    'user can file bugs in Firefox'
  );

  throws_error(
    sub { $ws->check_user_permission_for_bug({bug_id => $bug->id}) },
    'bugzilla.user.phabricator_invalid_request_params',
    'user_id is required'
  );
  throws_error(
    sub { $ws->check_user_enter_bug_permission({user_id => $author->id}) },
    'bugzilla.user.phabricator_invalid_request_params',
    'product is required'
  );

  $env->fresh_request($author);
  throws_error(
    sub {
      $ws->check_user_permission_for_bug({bug_id => $bug->id, user_id => $author->id
      });
    },
    'bugzilla.user.phabricator_unauthorized_user',
    'only phab-bot may call check_bug'
  );
  throws_error(
    sub {
      $ws->check_user_enter_bug_permission({
        product => 'Firefox', user_id => $author->id
      });
    },
    'bugzilla.user.phabricator_unauthorized_user',
    'only phab-bot may call check_enter_bug'
  );
}

# Everything is refused while the integration is disabled
{
  $env->fresh_request($env->phab_bot);
  SetParam('phabricator_enabled', 0);
  $conduit->reset_calls;
  throws_error(
    sub { $ws->bug_revisions({bug_id => $bug->id}) },
    'bugzilla.user.phabricator_not_enabled',
    'bug_revisions disabled'
  );
  throws_error(
    sub { $ws->user({user_id => $author->id}) },
    'bugzilla.user.phabricator_not_enabled',
    'user disabled'
  );
  throws_error(
    sub {
      $ws->check_user_permission_for_bug({bug_id => $bug->id, user_id => $author->id
      });
    },
    'bugzilla.user.phabricator_not_enabled',
    'check_bug disabled'
  );
  is($conduit->call_count, 0, 'no Conduit calls while disabled');
  $conduit->apply_params;
}

$env->fresh_request;
$env->finish;
done_testing;
