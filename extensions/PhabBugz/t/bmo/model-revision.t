#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Revision: differential.revision.search lookups, the lazy
# builders (author, reviews, subscribers, projects, repository, comments),
# the transactions built by the mutators and the privacy helpers.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Digest::SHA qw(sha1_hex);
use Storable    qw(dclone);
use Test::More;

use Bugzilla::Extension::PhabBugz::Policy;
use Bugzilla::Extension::PhabBugz::Revision;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

use constant Revision => 'Bugzilla::Extension::PhabBugz::Revision';

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

my $author        = $env->bmo_user('author');
my $author_phab   = $env->link_user($author);
my $reviewer      = $env->bmo_user('reviewer');
my $reviewer_phab = $env->link_user($reviewer);
my $subscriber
  = $conduit->add_user(user_obj(username => 'phabtest-subscriber'));

my $review_group
  = $conduit->add_project(project_obj(name => $env->unique('reviewers')));
my $tag = $conduit->add_project(project_obj(name => $env->unique('tag')));
my $bmo_group
  = $conduit->add_project(project_obj(name => 'bmo-' . $env->unique('grp')));
my $secure   = $conduit->add_project(project_obj(name => 'secure-revision'));
my $editbugs = $conduit->add_project(project_obj(name => 'bmo-editbugs-team'));
my $repo
  = $conduit->add_repository(repository_obj(short_name => 'firefox-beta'));

my $bug = $env->bug;

my $raw = $conduit->add_revision(revision_obj(
  title           => 'Bug fix',
  summary         => 'Fixes the bug',
  status          => 'needs-review',
  bug_id          => '  ' . $bug->id . ' ',
  author_phid     => $author_phab->{phid},
  diff_phid       => 'PHID-DIFF-current',
  repository_phid => $repo->{phid},
  is_draft        => 0,
  hold_as_draft   => 1,
  subscribers     => [$subscriber->{phid}, $reviewer_phab->{phid}],
  projects        => [$tag->{phid}, $bmo_group->{phid}, $secure->{phid}],
  reviewers       => [
    {
      phid     => $reviewer_phab->{phid},
      status   => 'accepted',
      blocking => 1,
      actor    => $reviewer_phab->{phid}
    },
    {phid => $review_group->{phid},        status => 'added'},
    {phid => 'PHID-USER-notinphabricator', status => 'added'},
    {phid => 'PHID-OPKG-somepackage',      status => 'added'},
  ],
  reviewers_extra => [
    {phid => $reviewer_phab->{phid}, diff => 'PHID-DIFF-previous', voided => undef},
  ],
));

sub load { return Revision->new_from_query({phids => [$raw->{phid}]}) }

# new_from_query
{
  $conduit->reset_calls;
  my $revision = load();
  is_deeply(
    [$conduit->calls('differential.revision.search')],
    [{
      queryKey    => 'all',
      attachments => {projects => 1, reviewers => 1, subscribers => 1},
      constraints => {phids    => [$raw->{phid}]},
    }],
    'differential.revision.search params'
  );
  is($revision->bug_id, $bug->id, 'whitespace around bugzilla.bug-id is removed');

  is(Revision->new_from_query({ids => [$raw->{id}]})->phid,
    $raw->{phid}, 'lookup by ids');
  is(Revision->new_from_query({phids => ['PHID-DREV-missing']}),
    undef, 'unknown revision returns undef');

  my $no_bug
    = $conduit->add_revision(revision_obj(author_phid => $author_phab->{phid}));
  is(Revision->new_from_query({phids => [$no_bug->{phid}]})->bug_id,
    '', 'null bug id becomes an empty string');
}

# Constructor maps Conduit fields
{
  my $revision = load();
  is($revision->id,      $raw->{id},      'id');
  is($revision->title,   'Bug fix',       'title');
  is($revision->summary, 'Fixes the bug', 'summary');
  is($revision->status,  'needs-review',  'status from status.value');
  ok(!$revision->is_draft,     'isDraft');
  ok($revision->hold_as_draft, 'holdAsDraft');
  is($revision->author_phid,      $author_phab->{phid}, 'author_phid');
  is($revision->diff_phid,        'PHID-DIFF-current',  'diff_phid');
  is($revision->repository_phid,  $repo->{phid},        'repository_phid');
  is($revision->view_policy,      'public',             'view policy');
  is($revision->edit_policy,      'users',              'edit policy');
  is($revision->subscriber_count, 2,                    'subscriber_count');
  is($revision->bug->id,          $bug->id,             'bug loads the BMO bug');
  ok(!$revision->is_private, 'public revision is not private');
  is($revision->secured_title, 'Bug fix', 'secured_title of a public revision');
}

# author
{
  my $revision = load();
  $conduit->reset_calls;
  is($revision->author->phid,              $author_phab->{phid}, 'author');
  is($revision->author->bugzilla_user->id, $author->id, 'author BMO account');
  $revision->author;
  is($conduit->call_count('user.search'), 1, 'author is loaded once');
}

# reviews. new_from_query does not request reviewers-extra, so build the
# revision from the full fixture (as WebService does with its own search).
{
  my $revision = Revision->new(dclone($raw));
  $conduit->reset_calls;
  my $reviews = $revision->reviews;
  is(scalar @$reviews,
    2, 'unknown users and non user/project reviewers (packages) are skipped');

  my ($user_review)    = grep { !$_->{is_project} } @$reviews;
  my ($project_review) = grep { $_->{is_project} } @$reviews;
  is($user_review->{user}->phid, $reviewer_phab->{phid}, 'user reviewer');
  is($user_review->{status},
    'accepted-prior', 'accepted on an older diff becomes accepted-prior');
  is($user_review->{is_blocking},    1,                     'blocking reviewer');
  is($project_review->{user}->phid,  $review_group->{phid}, 'project reviewer');
  is($project_review->{status},      'added', 'project reviewer status');
  is($project_review->{is_blocking}, 0,       'non-blocking reviewer');

  my $current = dclone($raw);
  $current->{attachments}{'reviewers-extra'}{'reviewers-extra'}[0]{diffPHID}
    = 'PHID-DIFF-current';
  my $same_diff = Revision->new($current);
  my ($accepted) = grep { !$_->{is_project} } @{$same_diff->reviews};
  is($accepted->{status}, 'accepted',
    'accepted on the current diff stays accepted');

  my ($loaded) = grep { !$_->{is_project} } @{load()->reviews};
  is($loaded->{status}, 'accepted',
    'without reviewers-extra (new_from_query) accepted stays accepted');
}

# subscribers and projects
{
  my $revision = load();
  $conduit->reset_calls;
  is_deeply(
    [sort map { $_->phid } @{$revision->subscribers}],
    [sort $subscriber->{phid}, $reviewer_phab->{phid}],
    'subscribers'
  );
  is($conduit->call_count('user.search'), 1, 'subscribers in one user.search');

  is_deeply([map { $_->phid } @{$revision->projects}],
    [$tag->{phid}, $bmo_group->{phid}, $secure->{phid}], 'projects');
  is($conduit->call_count('project.search'), 3, 'one project.search per project');
}

# repository is cached per request
{
  my $first  = load();
  my $second = load();
  delete Bugzilla->request_cache->{phab_repo_cache};
  $conduit->reset_calls;
  is($first->repository->phid,       $repo->{phid},  'repository');
  is($first->repository->short_name, 'firefox-beta', 'repository short name');
  is($second->repository->phid,
    $repo->{phid}, 'same repository for a second revision');
  is($conduit->call_count('diffusion.repository.search'),
    1, 'repository fetched once per request');

  my $no_repo = Revision->new(
    revision_obj(author_phid => $author_phab->{phid}, bug_id => ''));
  $conduit->reset_calls;
  is($no_repo->repository, undef, 'revision without a repository');
  is($conduit->call_count, 0,     'no Conduit call without a repository PHID');
}

# comments
{
  $conduit->add_transaction(
    $raw->{phid},
    transaction_obj(
      object_phid => $raw->{phid},
      author_phid => $reviewer_phab->{phid},
      comments    => ['Looks good to me'],
    )
  );
  $conduit->add_transaction($raw->{phid},
    transaction_obj(object_phid => $raw->{phid}, type => 'accept'));
  $conduit->add_transaction($raw->{phid},
    transaction_obj(object_phid => $raw->{phid}, type => undef));

  my $revision = load();
  $conduit->reset_calls;
  my $comments = $revision->comments;
  is_deeply(
    [$conduit->calls('transaction.search')],
    [{objectIdentifier => $raw->{phid}}],
    'transaction.search params'
  );
  is(scalar @$comments,    1, 'only comment transactions are returned');
  is($comments->[0]->text, 'Looks good to me', 'comment text from content.raw');
  is($comments->[0]->author_phid, $reviewer_phab->{phid}, 'comment author PHID');
  is($comments->[0]->author->phid, $reviewer_phab->{phid},
    'comment author loads');
}

# stack_graph
{
  my $parent  = 'PHID-DREV-parent';
  my $child   = $raw->{phid};
  my $stacked = Revision->new(revision_obj(
    phid        => $child,
    bug_id      => '',
    author_phid => $author_phab->{phid},
    stack_graph => {$child => [$parent], $parent => []},
  ));
  my $graph = $stacked->stack_graph;
  is_deeply(
    [sort @{$graph->{phids}}],
    [sort $parent, $child],
    'stack graph nodes'
  );
  is_deeply($graph->{edges}, [[$child, $parent]], 'stack graph edges');
}

# Mutators build the transactions sent by update
{
  my $revision = load();
  my $reviewer_user
    = Bugzilla::Extension::PhabBugz::User->new(dclone($reviewer_phab));
  my $tag_project = Bugzilla::Extension::PhabBugz::Project->new(dclone($tag));

  $revision->add_comment("  First comment\n");
  $revision->add_comment('Second comment');
  $revision->set_subscribers(['PHID-USER-set']);
  $revision->add_subscriber($reviewer_user);
  $revision->remove_subscriber('PHID-USER-gone');
  $revision->set_reviewers([$reviewer_user]);
  $revision->add_reviewer('blocking(PHID-PROJ-x)');
  $revision->remove_reviewer($reviewer_user);
  $revision->set_policy('view', 'PHID-PLCY-view');
  $revision->set_policy('edit', 'PHID-PLCY-edit');
  $revision->set_status('request-review');
  $revision->add_project($tag_project);
  ok(!defined $revision->add_project(undef), 'add_project ignores undef');
  $revision->remove_project('PHID-PROJ-old');

  $conduit->reset_calls;
  $revision->update;
  my ($edit) = $conduit->calls('differential.revision.edit');
  is($edit->{objectIdentifier}, $raw->{phid}, 'update targets the revision');

  my @transactions = @{$edit->{transactions}};
  my $status       = first_of(\@transactions, 'request-review');
  ok($status && $status->{value}, 'status transaction has value true');
  $_->{value} = 'true' for grep { $_->{type} eq 'request-review' } @transactions;

  is_deeply(
    \@transactions,
    [
      {type => 'comment',            value => 'First comment'},
      {type => 'comment',            value => 'Second comment'},
      {type => 'subscribers.set',    value => ['PHID-USER-set']},
      {type => 'subscribers.add',    value => [$reviewer_phab->{phid}]},
      {type => 'subscribers.remove', value => ['PHID-USER-gone']},
      {type => 'reviewers.set',      value => [$reviewer_phab->{phid}]},
      {type => 'reviewers.add',      value => ['blocking(PHID-PROJ-x)']},
      {type => 'reviewers.remove',   value => [$reviewer_phab->{phid}]},
      {type => 'view',               value => 'PHID-PLCY-view'},
      {type => 'edit',               value => 'PHID-PLCY-edit'},
      {type => 'request-review',     value => 'true'},
      {type => 'projects.add',       value => [$tag->{phid}]},
      {type => 'projects.remove',    value => ['PHID-PROJ-old']},
    ],
    'update sends every pending change, in order'
  );

  $conduit->queue(
    'differential.revision.edit' => conduit_error('ERR-CONDUIT-CORE', 'Locked'));
  throws_error(
    sub { $revision->update },
    'bugzilla.code.phabricator_api_error',
    'differential.revision.edit error propagates'
  );
}

# make_private
{
  my $revision = load();
  $conduit->reset_calls;
  $revision->make_private([$bmo_group->{fields}{name}]);

  is_deeply(
    [map { $_->{constraints} } $conduit->calls('project.search')],
    [{name => $bmo_group->{fields}{name}}],
    'group project looked up by name'
  );
  my ($create) = $conduit->calls('policy.create');
  is_deeply(
    $create->{policy}[-1]{value},
    [$bmo_group->{phid}],
    'new policy allows the group project'
  );

  my ($policy_query) = $conduit->calls('policy.query');
  my $policy_phid = $policy_query->{phids}[0];
  ok($revision->is_private, 'revision is now private');
  is($revision->secured_title, '(secure)', 'secured_title hides the title');

  $conduit->reset_calls;
  $revision->update;
  is_deeply(
    [$conduit->transactions_for($raw->{phid})],
    [
      {type => 'view', value => $policy_phid},
      {type => 'edit', value => $policy_phid}
    ],
    'view and edit policies set to the new custom policy'
  );
}

# make_public
{
  my $revision = load();
  $conduit->reset_calls;
  $revision->make_public;
  $revision->update;
  is_deeply(
    [$conduit->transactions_for($raw->{phid})],
    [
      {type => 'view',            value => 'public'},
      {type => 'edit',            value => $editbugs->{phid}},
      {type => 'projects.remove', value => [$bmo_group->{phid}, $secure->{phid}]},
    ],
    'public policy, editbugs edit policy, bmo-* and secure-revision tags removed'
  );
  ok(!$revision->is_private, 'revision is public');

  $editbugs->{fields}{name} = 'bmo-editbugs-team-renamed';
  my $fallback = load();
  $conduit->reset_calls;
  $fallback->make_public;
  $fallback->update;
  my ($edit_policy)
    = grep { $_->{type} eq 'edit' } $conduit->transactions_for($raw->{phid});
  is($edit_policy->{value}, 'users',
    'edit policy falls back to "users" without bmo-editbugs-team');
  $editbugs->{fields}{name} = 'bmo-editbugs-team';
}

# set_private_project_tags
{
  my $revision = load();
  $conduit->reset_calls;
  $revision->set_private_project_tags([$bmo_group->{fields}{name}]);
  $revision->update;
  is_deeply(
    [$conduit->transactions_for($raw->{phid})],
    [{type => 'projects.add', value => [$secure->{phid}, $bmo_group->{phid}]}],
    'secure-revision and group project tags added'
  );
}

# uplift_hash
{
  my $form = {
    'Is Android affected?'      => 'yes',
    'Explanation of risk level' => 'low',
    'Steps to reproduce'        => 'none',
    'Needs manual QE?'          => 'no',
    'Risk to taking this patch' => 'medium',
    'String changes made?'      => 'no',
  };
  my $revision = Revision->new(revision_obj(
    author_phid => 'x', bug_id => '', uplift_request => $form));

  # Perl hash order is random per process, so the hash only matches this
  # hand-written, key-sorted JSON if the encoder sorts keys.
  my $canonical = '{' . join(',', map {qq{"$_":"$form->{$_}"}} sort keys %$form) . '}';
  is($revision->uplift_hash, sha1_hex($canonical),
    'uplift_hash is sha1 of the form as key-sorted JSON');
}

sub first_of {
  my ($transactions, $type) = @_;
  my ($found) = grep { $_->{type} eq $type } @$transactions;
  return $found;
}

$env->finish;
done_testing;
