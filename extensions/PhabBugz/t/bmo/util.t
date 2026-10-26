#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Util helpers that combine BMO data with Conduit calls: bug role
# PHIDs, revision attachments, bug auto-assignment, reviewer rotation and
# intermittent reviewer handling.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test::More;

use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Revision;
use Bugzilla::Extension::PhabBugz::Util qw(
  create_revision_attachment
  get_attachment_revisions
  get_bug_role_phids
  set_bug_assignee
  set_intermittent_reviewers
  set_reviewer_rotation
);
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

use constant Revision => 'Bugzilla::Extension::PhabBugz::Revision';

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $dbh     = Bugzilla->dbh;

my $admin_phab  = $env->link_user($env->admin);
my $author      = $env->bmo_user('author');
my $author_phab = $env->link_user($author);
my $alice       = $env->bmo_user('alice');
my $alice_phab  = $env->link_user($alice);
my $bob         = $env->bmo_user('bob');
my $bob_phab    = $env->link_user($bob);
my $carol       = $env->bmo_user('carol-not-in-phab');

my ($timestamp) = $dbh->selectrow_array('SELECT NOW()');
my @rotation_projects;
$env->on_teardown(sub {
  $dbh->do('DELETE FROM phab_reviewer_rotation WHERE project_phid = ?', undef, $_)
    foreach @rotation_projects;
});

sub revision_for {
  my ($bug, %args) = @_;
  return $conduit->load_revision(revision_obj(
    bug_id      => ($bug ? $bug->id : ''),
    author_phid => $author_phab->{phid},
    %args,
  ));
}

# get_bug_role_phids
{
  my $bug = $env->bug(assigned_to => $alice, cc => [$bob, $carol]);
  $conduit->reset_calls;
  is_deeply(
    [sort @{get_bug_role_phids($bug)}],
    [sort $admin_phab->{phid}, $alice_phab->{phid}, $bob_phab->{phid}],
    'reporter, assignee and CCs with Phabricator accounts'
  );

  my $unassigned = $env->bug(cc => [$bob]);
  is_deeply(
    [sort @{get_bug_role_phids($unassigned)}],
    [sort $admin_phab->{phid}, $bob_phab->{phid}],
    'nobody@mozilla.org is not a role'
  );
}

# create_revision_attachment and get_attachment_revisions
{
  my $bug = $env->bug;
  my $revision
    = revision_for($bug, title => 'Attachment test', summary => 'Patch summary');

  my $attachment
    = create_revision_attachment($bug, $revision, $timestamp, $author);
  $bug->update($timestamp);    # the caller saves the attachment comment
  my $uri = $conduit->base_uri . 'D' . $revision->id;
  is($attachment->data, $uri, 'attachment data is the revision URL');
  is($attachment->filename, 'phabricator-D' . $revision->id . '-url.txt',
    'filename');
  is($attachment->contenttype,  PHAB_CONTENT_TYPE, 'Phabricator content type');
  is($attachment->description,  'Attachment test', 'description is the title');
  is($attachment->attacher->id, $author->id, 'attached by the revision author');

  my $fresh = Bugzilla::Bug->new($bug->id);
  my ($comment)
    = grep { ($_->extra_data // '') eq $attachment->id } @{$fresh->comments};
  ok($comment, 'attachment comment added');
  is(
    $comment->body,
    'Patch summary',
    'attachment comment is the revision summary'
  ) if $comment;

  my $again = create_revision_attachment($fresh, $revision, $timestamp, $author);
  is($again->id, $attachment->id, 'existing attachment is reused');
  is(scalar @{Bugzilla::Bug->new($bug->id)->attachments},
    1, 'no duplicate attachment');

  my $second = revision_for($bug);
  create_revision_attachment(Bugzilla::Bug->new($bug->id),
    $second, $timestamp, $author);

  $conduit->reset_calls;
  my $revisions = get_attachment_revisions(Bugzilla::Bug->new($bug->id));
  is_deeply(
    [sort map { $_->id } @$revisions],
    [sort $revision->id, $second->id],
    'get_attachment_revisions'
  );
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('differential.revision.search')],
    [map { {ids => [$_]} } $revision->id, $second->id],
    'one differential.revision.search per attachment'
  );

  ok(!get_attachment_revisions($env->bug), 'bug without revision attachments');

  my $private = revision_for($bug, view_policy => 'PHID-PLCY-private');
  is(
    create_revision_attachment(Bugzilla::Bug->new($bug->id),
      $private, $timestamp, $author)->description,
    '(secure)',
    'private revision attachments hide the title'
  );
}

# set_bug_assignee
{
  # Only NEW and UNCONFIRMED bugs move to ASSIGNED. Set the status directly
  # so the cases do not depend on the status Bug->create picks.
  foreach my $case (
    ['NEW',         'ASSIGNED'],
    ['UNCONFIRMED', 'ASSIGNED'],
    ['REOPENED',    'REOPENED']
    )
  {
    my ($initial, $expected) = @$case;
    my $bug = $env->bug;
    $dbh->do('UPDATE bugs SET bug_status = ? WHERE bug_id = ?',
      undef, $initial, $bug->id);
    $bug = Bugzilla::Bug->new($bug->id);
    my $revision = revision_for($bug, reviewers => [{phid => $alice_phab->{phid}}]);
    set_bug_assignee($revision, $bug, 'author updated D1');
    $bug->update;
    $bug = Bugzilla::Bug->new($bug->id);
    is($bug->assigned_to->id, $author->id,
      "unassigned $initial bug is assigned to the author");
    is($bug->bug_status, $expected, "$initial bug becomes $expected");
  }

  my $no_reviews = $env->bug;
  set_bug_assignee(revision_for($no_reviews), $no_reviews, 'author updated D1');
  $no_reviews->update;
  is(
    Bugzilla::Bug->new($no_reviews->id)->assigned_to->login,
    'nobody@mozilla.org',
    'revision without reviewers does not assign the bug'
  );

  my $assigned = $env->bug(assigned_to => $bob);
  set_bug_assignee(
    revision_for($assigned, reviewers => [{phid => $alice_phab->{phid}}]),
    $assigned, 'author updated D1');
  $assigned->update;
  is(Bugzilla::Bug->new($assigned->id)->assigned_to->id,
    $bob->id, 'an assigned bug keeps its assignee');
}

# set_reviewer_rotation
{
  my $bug     = $env->bug;
  my $project = $conduit->add_project(project_obj(
    name    => $env->unique('a') . '-reviewers-rotation',
    members => [$alice_phab->{phid}, $bob_phab->{phid}],
  ));
  push @rotation_projects, $project->{phid};

  my $pick = sub {
    my (%args) = @_;
    my $revision = revision_for(
      $bug,
      reviewers => [{phid => $project->{phid}, blocking => 1}],
      %args
    );
    $conduit->reset_calls;
    set_reviewer_rotation($revision);
    return [$conduit->transactions_for($revision->phid)];
  };

  is_deeply(
    $pick->(),
    [
      {type => 'subscribers.add',  value => [$project->{phid}]},
      {type => 'reviewers.add',    value => ["blocking($alice_phab->{phid})"]},
      {type => 'reviewers.remove', value => [$project->{phid}]},
    ],
    'first rotation picks the first member, keeps blocking, swaps the group'
  );
  my ($last)
    = $dbh->selectrow_array(
    'SELECT user_phid FROM phab_reviewer_rotation WHERE project_phid = ?',
    undef, $project->{phid});
  is($last, $alice_phab->{phid},
    'last reviewer stored in phab_reviewer_rotation');

  my ($next) = grep { $_->{type} eq 'reviewers.add' } @{$pick->()};
  is_deeply(
    $next->{value},
    ["blocking($bob_phab->{phid})"],
    'rotation moves to the next member'
  );

  ($next) = grep { $_->{type} eq 'reviewers.add' } @{$pick->()};
  is_deeply(
    $next->{value},
    ["blocking($alice_phab->{phid})"],
    'rotation wraps around'
  );

  ($next)
    = grep { $_->{type} eq 'reviewers.add' }
    @{$pick->(author_phid => $bob_phab->{phid})};
  is_deeply(
    $next->{value},
    ["blocking($alice_phab->{phid})"],
    'the revision author is never picked'
  );

  my $manual = $pick->(reviewers =>
      [{phid => $project->{phid}, blocking => 1}, {phid => $bob_phab->{phid}},]);
  is_deeply(
    $manual,
    [
      {type => 'subscribers.add',  value => [$project->{phid}]},
      {type => 'reviewers.remove', value => [$project->{phid}]},
    ],
    'a member already set as reviewer replaces the group without a new pick'
  );

  my $loose = $conduit->add_project(project_obj(
    name    => $env->unique('b') . '-reviewer-rotation',
    members => [$bob_phab->{phid}],
  ));
  push @rotation_projects, $loose->{phid};
  my $revision = revision_for($bug, reviewers => [{phid => $loose->{phid}}]);
  $conduit->reset_calls;
  set_reviewer_rotation($revision);
  my ($add)
    = grep { $_->{type} eq 'reviewers.add' }
    $conduit->transactions_for($revision->phid);
  is_deeply(
    $add->{value},
    [$bob_phab->{phid}],
    'non-blocking group gives a non-blocking reviewer (single member)'
  );
}

# set_reviewer_rotation when nobody is available
{
  my $bug     = $env->bug;
  my $project = $conduit->add_project(project_obj(
    name    => $env->unique('c') . '-reviewers-rotation',
    members => [$author_phab->{phid}],
  ));
  push @rotation_projects, $project->{phid};

  my $revision = revision_for($bug, reviewers => [{phid => $project->{phid}}]);
  $conduit->reset_calls;
  set_reviewer_rotation($revision);
  my ($comment)
    = grep { $_->{type} eq 'comment' }
    $conduit->transactions_for($revision->phid);
  like(
    $comment->{value} // '',
    qr/^REVIEWER ROTATION: .* \Q$project->{fields}{name}\E/,
    'comment explains that no reviewer was found'
  );

  $conduit->add_transaction(
    $revision->phid,
    transaction_obj(
      object_phid => $revision->phid,
      comments    => [$comment->{value} // ''],
    )
  );
  $conduit->reset_calls;
  set_reviewer_rotation(Revision->new_from_query({phids => [$revision->phid]}));
  ok(
    !(grep { $_->{type} eq 'comment' } $conduit->transactions_for($revision->phid)),
    'the comment is not repeated'
  );

  my $empty = $conduit->add_project(project_obj(
    name => $env->unique('d') . '-reviewers-rotation', members => [],));
  $conduit->reset_calls;
  set_reviewer_rotation(
    revision_for($bug, reviewers => [{phid => $empty->{phid}}]));
  ok(
    !(
      grep { $_->{type} eq 'reviewers.add' }
      map  { @{$_->{transactions}} } $conduit->calls('differential.revision.edit')
    ),
    'a group without members is skipped'
  );

  my $plain
    = $conduit->add_project(project_obj(name => $env->unique('plain-reviewers')));
  my $not_rotation = revision_for($bug, reviewers => [{phid => $plain->{phid}}]);
  $conduit->reset_calls;
  set_reviewer_rotation($not_rotation);
  is($conduit->call_count('differential.revision.edit'),
    0, 'no edit without a reviewer rotation group');
}

# set_intermittent_reviewers
{
  my $intermittent = $conduit->find_project(name => 'intermittent-reviewers')
    // $conduit->add_project(project_obj(name => 'intermittent-reviewers'));
  my $taskgraph = $conduit->find_project(name => 'taskgraph-reviewers')
    // $conduit->add_project(project_obj(name => 'taskgraph-reviewers'));
  my $other_blocking
    = $conduit->add_project(project_obj(name => $env->unique('other')));
  my $non_blocking
    = $conduit->add_project(project_obj(name => $env->unique('nonblock')));

  my $revision = revision_for(
    undef,
    reviewers => [
      {phid => $intermittent->{phid},   blocking => 1},
      {phid => $taskgraph->{phid},      blocking => 1},
      {phid => $other_blocking->{phid}, blocking => 1},
      {phid => $non_blocking->{phid}},
    ]
  );
  $conduit->reset_calls;
  set_intermittent_reviewers($revision);
  is_deeply(
    [$conduit->transactions_for($revision->phid)],
    [
      {type => 'subscribers.add',  value => [$other_blocking->{phid}]},
      {type => 'reviewers.remove', value => [$other_blocking->{phid}]},
    ],
    'other blocking groups move to subscribers'
  );

  my $only_one = revision_for(
    undef,
    reviewers => [
      {phid => $intermittent->{phid},   blocking => 1},
      {phid => $other_blocking->{phid}, blocking => 1},
    ]
  );
  $conduit->reset_calls;
  set_intermittent_reviewers($only_one);
  is($conduit->call_count('differential.revision.edit'),
    0, 'nothing changes without both intermittent and taskgraph reviewers');
}

$env->finish;
done_testing;
