#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Repository (diffusion.repository.search, uplift detection) and
# PhabBugz::Comment (transaction.search comments).

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Storable qw(dclone);
use Test::More;

use Bugzilla::Extension::PhabBugz::Comment;
use Bugzilla::Extension::PhabBugz::Repository;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

use constant Repository => 'Bugzilla::Extension::PhabBugz::Repository';
use constant Comment    => 'Bugzilla::Extension::PhabBugz::Comment';

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

my $uplift_tag = $conduit->add_project(project_obj(name => 'uplift'));
my $other_tag = $conduit->add_project(project_obj(name => $env->unique('tag')));

my $beta = $conduit->add_repository(repository_obj(
  short_name => 'firefox-beta',
  callsign   => 'BETA',
  projects   => [$other_tag->{phid}, $uplift_tag->{phid}],
));
my $central = $conduit->add_repository(repository_obj(
  short_name => 'mozilla-central',
  projects   => [$other_tag->{phid}]
));

# new_from_query
{
  $conduit->reset_calls;
  my $repo = Repository->new_from_query({phids => [$beta->{phid}]});
  is_deeply(
    [$conduit->calls('diffusion.repository.search')],
    [{
      queryKey    => 'all',
      constraints => {phids    => [$beta->{phid}]},
      attachments => {projects => 1},
    }],
    'diffusion.repository.search params'
  );
  is($repo->phid,           $beta->{phid},  'phid');
  is($repo->name,           'firefox-beta', 'name');
  is($repo->short_name,     'firefox-beta', 'short name');
  is($repo->call_sign,      'BETA',         'callsign');
  is($repo->vcs,            'git',          'vcs');
  is($repo->status,         'active',       'status');
  is($repo->default_branch, 'main',         'default branch');
  is(
    $repo->description,
    'Repository firefox-beta',
    'description from description.raw'
  );
  is($repo->view_policy, 'public', 'view policy');
  is($repo->edit_policy, 'admin',  'edit policy');
  is($repo->push_policy, 'no-one', 'diffusion.push policy');

  is(Repository->new_from_query({phids => ['PHID-REPO-missing']}),
    undef, 'unknown repository returns undef');
}

# projects and is_uplift_repo
{
  my $beta_repo = Repository->new_from_query({phids => [$beta->{phid}]});
  $conduit->reset_calls;
  is_deeply(
    [map { $_->name } @{$beta_repo->projects}],
    [$other_tag->{fields}{name}, 'uplift'],
    'repository projects'
  );
  is($conduit->call_count('project.search'), 2, 'one project.search per project');
  ok($beta_repo->is_uplift_repo, 'repository tagged #uplift is an uplift repo');

  ok(!Repository->new_from_query({phids => [$central->{phid}]})->is_uplift_repo,
    'repository without #uplift is not an uplift repo');

  my $untagged = Repository->new(repository_obj());
  $conduit->reset_calls;
  ok(!$untagged->is_uplift_repo, 'repository without projects');
  is($conduit->call_count, 0, 'no project lookups for an untagged repository');
}

# Errors propagate
{
  $conduit->queue('diffusion.repository.search' => http_error(500));
  throws_error(
    sub { Repository->new_from_query({phids => [$beta->{phid}]}) },
    'bugzilla.code.phabricator_api_error',
    'diffusion.repository.search error'
  );
}

# Comment
{
  my $author      = $env->bmo_user('commenter');
  my $author_phab = $env->link_user($author);
  my $xact        = transaction_obj(
    author_phid => $author_phab->{phid},
    comments    => ["A comment\nwith two lines"],
  );
  my $comment = Comment->new(dclone($xact->{comments}[0]));

  is($comment->id,          $xact->{comments}[0]{id},    'id');
  is($comment->phid,        $xact->{comments}[0]{phid},  'phid');
  is($comment->text,        "A comment\nwith two lines", 'text from content.raw');
  is($comment->author_phid, $author_phab->{phid},        'author PHID');
  is($comment->creation_ts, 1507666113,                  'creation_ts');
  is($comment->modification_ts, 1507666113,              'modification_ts');

  $conduit->reset_calls;
  is($comment->author->bugzilla_user->id,
    $author->id, 'author loads the linked user');
  $comment->author;
  is($conduit->call_count('user.search'), 1, 'author is loaded once');
}

$env->finish;
done_testing;
