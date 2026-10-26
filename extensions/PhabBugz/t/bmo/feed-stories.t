#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The feed daemon's story loop (PhabBugz::Feed::feed_query): polling
# feed.query_id from the saved cursor, skipping stories it does not handle,
# syncing revisions to their bugs (attachments, privacy policies, project
# tags, subscribers, assignee, uplift requests) and the failure modes of
# the feed (invalid cursor, Conduit/HTTP/network errors, a story that keeps
# failing).

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

# Constants are inlined when PhabBugz::Feed compiles, so set this first.
BEGIN { $ENV{PHAB_FEED_MAX_RETRIES} = 3 }

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Digest::SHA        qw(sha1_hex);
use Mojo::JSON         qw(encode_json);
use Test2::Tools::Mock qw(mock);
use Test::More;

use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Feed;
use Bugzilla::Extension::PhabBugz::Util qw(is_attachment_phab_revision);
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $dbh     = Bugzilla->dbh;
my $feed    = Bugzilla::Extension::PhabBugz::Feed->new;

my $author        = $env->bmo_user('author');
my $author_phab   = $env->link_user($author, username => 'phabtest-author');
my $reviewer      = $env->bmo_user('reviewer');
my $reviewer_phab = $env->link_user($reviewer);
my $cc_user       = $env->bmo_user('cc');
my $cc_phab       = $env->link_user($cc_user);
my $unlinked = $conduit->add_user(user_obj(username => 'phabtest-unlinked'));

my $editbugs = $conduit->add_project(project_obj(name => 'bmo-editbugs-team'));
my $secure   = $conduit->add_project(project_obj(name => 'secure-revision'));
my $tag      = $conduit->add_project(project_obj(name => $env->unique('tag')));

# Story ids grow through the file; each scenario starts the cursor at the
# last id used so it only sees its own stories.
my $last_story_id = 7_000_000;

sub story {
  my (%args) = @_;
  $last_story_id += $args{gap} // 1;
  delete $args{gap};
  return $conduit->add_story(feed_story(
    id => $last_story_id, author_phid => $author_phab->{phid}, %args,));
}

sub start_scenario {
  $env->save_cursor('feed', $last_story_id);
  return $last_story_id;
}

sub run_feed { $env->run_sync(sub { $feed->feed_query }) }

sub revision {
  my (%args) = @_;
  return $conduit->add_revision(
    revision_obj(author_phid => $author_phab->{phid}, %args));
}

sub created_text {
  return "phabtest-author created D$_[0]{id}: $_[0]{fields}{title}.";
}
sub updated_text { return "phabtest-author updated D$_[0]{id}." }

sub phab_attachments {
  my ($bug_id) = @_;
  return
    grep { is_attachment_phab_revision($_) }
    @{Bugzilla::Bug->new($bug_id)->attachments};
}

# Sync disabled
{
  start_scenario();
  $env->sync_disabled_ok(sub { $feed->feed_query });
}

# A cursor of 0 asks for everything after story 1
{
  $env->save_cursor('feed', 0);
  ok(!run_feed(), 'feed_query with an empty feed');
  is_deeply(
    [$conduit->calls('feed.query_id')],
    [{view => 'text', after => 1}],
    'cursor 0 sends after => 1'
  );
}

# No new stories
{
  my $cursor = start_scenario();
  ok(!run_feed(), 'feed_query with no new stories');
  is_deeply(
    [$conduit->calls('feed.query_id')],
    [{view => 'text', after => $cursor}],
    'feed.query_id from the saved cursor'
  );
  is($env->cursor('feed'), $cursor, 'cursor unchanged');
}

# Stories are processed oldest first; non-revision and phab-bot stories are
# skipped but still advance the cursor
{
  start_scenario();
  my @saved;
  my $spy = mock 'Bugzilla::Extension::PhabBugz::Feed' =>
    (before => [save_last_id => sub { push @saved, $_[1] }]);

  my $task   = story(object_phid => 'PHID-TASK-sometask');
  my $by_bot = story(
    object_phid => revision()->{phid},
    author_phid => $env->phab_bot_phab->{phid}
  );
  my $commit = story(object_phid => 'PHID-CMIT-somecommit');

  ok(!run_feed(), 'feed_query with skipped stories');
  is_deeply(
    \@saved,
    [$task->{id}, $by_bot->{id}, $commit->{id}],
    'stories handled in ascending id order (Conduit returns newest first)'
  );
  is($env->cursor('feed'), $commit->{id}, 'cursor saved after the last story');
  is($conduit->call_count('differential.revision.search'),
    0, 'skipped stories do not load revisions');
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('user.search')],
    [{phids => [$env->phab_bot_phab->{phid}]}],
    'only the revision story author is looked up'
  );
}

# New revision without a bug is made public and leaves draft
{
  start_scenario();
  my $raw = revision(
    title    => 'No bug yet',
    status   => 'draft',
    is_draft => 1,
    projects => [$secure->{phid}, $tag->{phid}],
  );
  my $story = story(object_phid => $raw->{phid}, text => created_text($raw));

  ok(!run_feed(), 'feed_query for a new revision without a bug');
  my @transactions = $conduit->transactions_for($raw->{phid});
  $_->{value} = 'true' for grep { $_->{type} eq 'request-review' } @transactions;
  is_deeply(
    \@transactions,
    [
      {type => 'view',            value => 'public'},
      {type => 'edit',            value => $editbugs->{phid}},
      {type => 'request-review',  value => 'true'},
      {type => 'projects.remove', value => [$secure->{phid}]},
    ],
    'made public, secure-revision tag removed, moved out of draft'
  );
  is($env->cursor('feed'), $story->{id}, 'cursor advanced');
}

# Updates to a revision without a bug are ignored
{
  start_scenario();
  my $raw   = revision();
  my $story = story(object_phid => $raw->{phid}, text => updated_text($raw));
  ok(!run_feed(), 'feed_query for an updated revision without a bug');
  is($conduit->call_count('differential.revision.edit'), 0,
    'revision not edited');
  is($env->cursor('feed'), $story->{id}, 'cursor advanced');
}

# Revision on a public bug
{
  start_scenario();
  my $bug = $env->bug;
  my $raw = revision(
    title     => 'Public fix',
    summary   => 'Fixes the public bug',
    bug_id    => $bug->id,
    reviewers => [{phid => $reviewer_phab->{phid}}],
    projects  => [$tag->{phid}],
  );
  my $story = story(object_phid => $raw->{phid}, text => updated_text($raw));

  ok(!run_feed(), 'feed_query for a revision on a public bug');
  my @attachments = phab_attachments($bug->id);
  is(scalar @attachments, 1, 'revision attachment created');
  my $attachment = $attachments[0];
  is(
    $attachment->data,
    $conduit->base_uri . "D$raw->{id}",
    'attachment points to the revision'
  );
  is($attachment->description, 'Public fix',
    'attachment description is the title');
  is($attachment->attacher->id, $author->id, 'attached by the revision author');
  ok(!$attachment->isobsolete, 'attachment is not obsolete');

  is_deeply(
    [
      grep { $_->{type} =~ /^(view|edit)$/ } $conduit->transactions_for($raw->{phid})
    ],
    [
      {type => 'view', value => 'public'},
      {type => 'edit', value => $editbugs->{phid}}
    ],
    'public bug keeps the revision public'
  );

  my $fresh = Bugzilla::Bug->new($bug->id);
  is($fresh->assigned_to->id,
    $author->id, 'unassigned bug assigned to the author');
  is(
    $fresh->bug_status,
    ($bug->bug_status =~ /^(?:NEW|UNCONFIRMED)$/ ? 'ASSIGNED' : $bug->bug_status),
    'NEW/UNCONFIRMED bugs move to ASSIGNED, others keep their status'
  );
  is($env->cursor('feed'), $story->{id}, 'cursor advanced');

  # The same change seen again does not duplicate the attachment
  start_scenario();
  story(object_phid => $raw->{phid}, text => updated_text($raw));
  ok(!run_feed(), 'second story for the same revision');
  is(scalar(phab_attachments($bug->id)), 1, 'attachment reused');

  # Abandoning the revision obsoletes the attachment
  start_scenario();
  $raw->{fields}{status}{value} = 'abandoned';
  story(
    object_phid => $raw->{phid},
    text        => "phabtest-author abandoned D$raw->{id}."
  );
  ok(!run_feed(), 'story for an abandoned revision');
  ok((phab_attachments($bug->id))[0]->isobsolete, 'attachment obsoleted');

  # Moving the revision to another bug obsoletes the old attachment
  start_scenario();
  $raw->{fields}{status}{value} = 'needs-review';
  my $new_bug = $env->bug;
  $raw->{fields}{'bugzilla.bug-id'} = $new_bug->id;
  my ($old) = phab_attachments($bug->id);
  $old->set_is_obsolete(0);
  $old->update;
  story(object_phid => $raw->{phid}, text => updated_text($raw));
  ok(!run_feed(), 'story after the bug id changed');
  is(scalar(phab_attachments($new_bug->id)),
    1, 'attachment created on the new bug');
  ok(
    (phab_attachments($bug->id))[0]->isobsolete,
    'attachment on the old bug obsoleted'
  );
  my ($moved_comment)
    = grep { $_->body =~ /was moved to bug/ }
    @{Bugzilla::Bug->new($bug->id)->comments};
  like(
    $moved_comment ? $moved_comment->body : '',
    qr/Revision D$raw->{id} was moved to bug ${\ $new_bug->id}/,
    'old bug gets a comment'
  );
}

# Revision on a private bug
{
  my $group   = $env->bug_group('secret');
  my $project = $conduit->add_project(project_obj(name => 'bmo-' . $group->name));
  $env->add_to_group($author, $group);
  my $bug        = $env->bug(groups => [$group], cc => [$cc_user]);
  my $admin_phab = $env->link_user($env->admin);

  start_scenario();
  my $raw = revision(title => 'Secret fix', bug_id => $bug->id);
  story(object_phid => $raw->{phid}, text => updated_text($raw));

  ok(!run_feed(), 'feed_query for a revision on a private bug');
  my ($create) = $conduit->calls('policy.create');
  ok($create, 'custom policy created');
  is_deeply(
    $create->{policy}[-1]{value},
    [$project->{phid}],
    'policy allows the bmo-<group> project'
  );
  my ($query) = $conduit->calls('policy.query');
  my $policy_phid = $query->{phids}[0];

  my %by_type
    = map { $_->{type} => $_->{value} } $conduit->transactions_for($raw->{phid});
  is($by_type{view}, $policy_phid, 'view policy is the custom policy');
  is($by_type{edit}, $policy_phid, 'edit policy is the custom policy');
  is_deeply(
    $by_type{'projects.add'},
    [$secure->{phid}, $project->{phid}],
    'secure-revision and group tags added'
  );
  is_deeply(
    [sort @{$by_type{'subscribers.set'}}],
    [sort $admin_phab->{phid}, $cc_phab->{phid}],
    'subscribers set to the bug reporter and CCs'
  );
  is((phab_attachments($bug->id))[0]->description,
    '(secure)', 'attachment title hidden');

  # The revision already has a matching policy: no new policy
  start_scenario();
  $raw->{fields}{policy}{view} = $policy_phid;
  story(object_phid => $raw->{phid}, text => updated_text($raw));
  ok(!run_feed(), 'second story for the private revision');
  is($conduit->call_count('policy.create'), 0, 'matching policy is kept');
  ok(
    (
      grep { $_->{type} eq 'subscribers.set' }
        $conduit->transactions_for($raw->{phid})
    ),
    'subscribers still synced'
  );

  # Another group on the bug: the policy no longer matches
  my $group2 = $env->bug_group('secret2');
  my $project2
    = $conduit->add_project(project_obj(name => 'bmo-' . $group2->name));
  $dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
    undef, $bug->id, $group2->id);
  $env->add_to_group($author, $group2);
  start_scenario();
  story(object_phid => $raw->{phid}, text => updated_text($raw));
  ok(!run_feed(), 'story after a group was added to the bug');
  my ($recreate) = $conduit->calls('policy.create');
  ok($recreate, 'policy recreated');
  is_deeply(
    [sort @{$recreate ? $recreate->{policy}[-1]{value} : []}],
    [sort $project->{phid}, $project2->{phid}],
    'new policy covers both groups'
  );
}

# Invalid bug id, or a bug the author cannot see
{
  start_scenario();
  my $missing = revision(bug_id => '2147483000');
  story(object_phid => $missing->{phid}, text => updated_text($missing));
  ok(!run_feed(), 'feed_query for a revision with an invalid bug id');
  my ($comment)
    = grep { $_->{type} eq 'comment' }
    $conduit->transactions_for($missing->{phid});
  like(
    $comment->{value} // '',
    qr/kept private due to invalid/,
    'author is told the bug id is invalid'
  );
TODO: {
    local $TODO
      = 'revision/comments.html.tmpl does not load terms, so "bug" is blank';
    like($comment->{value} // '', qr/invalid bug ID/, 'comment says "bug ID"');
  }

  start_scenario();
  my $new_missing = revision(bug_id => '2147483001');
  story(object_phid => $new_missing->{phid}, text => created_text($new_missing));
  ok(!run_feed(), 'feed_query for a new revision with an invalid bug id');
  is($conduit->call_count('differential.revision.edit'),
    0, 'new revisions are left alone until the next update');

  my $group      = $env->bug_group('hidden');
  my $hidden_bug = $env->bug(groups => [$group]);
  start_scenario();
  my $hidden = revision(bug_id => $hidden_bug->id);
  story(object_phid => $hidden->{phid}, text => updated_text($hidden));
  ok(!run_feed(), 'feed_query for a bug the author cannot see');
  ok(
    (grep { $_->{type} eq 'comment' } $conduit->transactions_for($hidden->{phid})),
    'author is told they cannot access the bug'
  );
  is(scalar(phab_attachments($hidden_bug->id)),
    0, 'no attachment on the hidden bug');
}

# Story author without a BMO account: phab-bot is used as the changer
{
  Bugzilla->memcached->clear({key => 'phab_user_bugzilla_id_' . $env->phab_bot->id
  });
  start_scenario();
  my $bug = $env->bug;
  my $raw = revision(bug_id => $bug->id);
  story(
    object_phid => $raw->{phid},
    author_phid => $unlinked->{phid},
    text        => "phabtest-unlinked updated D$raw->{id}."
  );
  ok(!run_feed(), 'feed_query for a story by an unlinked user');
  my ($lookup) = $conduit->calls('bugzilla.account.search');
  is_deeply(
    $lookup,
    {ids => [$env->phab_bot->id]},
    'phab-bot looked up as the changer'
  );
  is(scalar(phab_attachments($bug->id)), 1, 'revision still synced to the bug');
}

# Uplift request form
{
  my $relman = $conduit->add_project(project_obj(name => 'release-managers'));
  my $repo
    = $conduit->add_repository(repository_obj(short_name => 'firefox-beta'));
  my $bug  = $env->bug;
  my $form = {
    'User impact if declined'  => 'Crash on startup',
    'Needs manual QE testing?' => 'yes',
    'Is Android affected?'     => '0',
    'Not a known question'     => 'ignored',
  };
  my $raw = revision(
    bug_id          => $bug->id,
    repository_phid => $repo->{phid},
    uplift_request  => $form,
  );
  $env->on_teardown(sub {
    $dbh->do('DELETE FROM phab_uplift_form_state WHERE revision_phid = ?',
      undef, $raw->{phid});
  });

  start_scenario();
  story(
    object_phid => $raw->{phid},
    text => "phabtest-author updated the uplift request field for D$raw->{id}."
  );
  ok(!run_feed(), 'feed_query for an uplift request form change');

  my $fresh = Bugzilla::Bug->new($bug->id);
  my ($comment)
    = grep { $_->body =~ /Uplift Approval Request/ } @{$fresh->comments};
  ok($comment, 'uplift form copied to the bug');
  my $body = $comment ? $comment->body : '';
  like($body, qr/^### firefox-beta Uplift Approval Request$/m, 'comment heading');
  like(
    $body,
    qr/^- \*\*User impact if declined\/Reason for urgency\*\*: Crash on startup$/m,
    'old form keys are mapped to the current label'
  );
  like($body, qr/^- \*\*Is Android affected\?\*\*: no$/m, '0 is shown as "no"');
  unlike($body, qr/Not a known question/, 'unknown questions are left out');

  my ($add)
    = grep { $_->{type} eq 'reviewers.add' }
    $conduit->transactions_for($raw->{phid});
  is_deeply(
    $add->{value},
    ["blocking($relman->{phid})"],
    '#release-managers added as a blocking reviewer'
  );

  my ($qe) = grep { $_->name eq 'qe-verify' } @{$fresh->flags};
  is($qe ? $qe->status : '', '+', 'qe-verify+ set when manual QE is needed');

  my ($hash)
    = $dbh->selectrow_array(
    'SELECT uplift_form_hash FROM phab_uplift_form_state WHERE revision_phid = ?',
    undef, $raw->{phid});
  is($hash, sha1_hex(encode_json($form)), 'form hash saved');
  is(scalar(phab_attachments($bug->id)),
    0, 'an uplift form story returns before the normal sync');

  # Same form again: no second comment, normal sync runs
  start_scenario();
  story(object_phid => $raw->{phid}, text => updated_text($raw));
  ok(!run_feed(), 'feed_query for a later change with the same form');
  is(
    scalar(
      grep { $_->body =~ /Uplift Approval Request/ }
        @{Bugzilla::Bug->new($bug->id)->comments}
    ),
    1,
    'form not copied again'
  );
  is(scalar(phab_attachments($bug->id)), 1, 'normal sync ran');
}

# feed.query_id reports an invalid cursor: retry with the next id until it
# names a story. Like Conduit, that story is the new `after` and is not
# returned itself, only the ones after it.
{
  my $cursor = start_scenario();
  $conduit->queue('feed.query_id' => cursor_invalid($cursor));
  my $anchor = story(object_phid => 'PHID-TASK-anchor', gap => 2);
  my $story  = story(object_phid => 'PHID-TASK-retry');
  ok(!run_feed(), 'feed_query recovers from an invalid cursor');
  is_deeply(
    [map { $_->{after} } $conduit->calls('feed.query_id')],
    [$cursor, $cursor + 1, $anchor->{id}],
    'retried with after + 1 until it named a story'
  );
  is($env->cursor('feed'), $story->{id}, 'story after the gap processed');
}

# One page of stories per run; the rest come on the next run
{
  my $cursor  = start_scenario();
  my @stories = map { story(object_phid => "PHID-TASK-page$_") } 1 .. 3;
  my $guard   = $conduit->local_page_size(2);
  ok(!run_feed(), 'first page of stories');
  is($env->cursor('feed'), $stories[1]{id}, 'cursor at the end of the page');
  ok(!run_feed(), 'second page of stories');
  is_deeply(
    [map { $_->{after} } $conduit->calls('feed.query_id')],
    [$stories[1]{id}],
    'second run continues from the saved cursor'
  );
  is($env->cursor('feed'), $stories[2]{id}, 'cursor at the last story');
}

# ... but gives up after PHAB_FEED_MAX_RETRIES
{
  my $cursor = start_scenario();
  $conduit->queue('feed.query_id' => cursor_invalid($cursor + $_)) for 0 .. 2;
  my $error = with_typed_errors(sub { run_feed() });
  is(
    ref $error && $error->type,
    'bugzilla.code.phabricator_api_error',
    'feed_query throws after the retries'
  );
  is_deeply(
    [map { $_->{after} } $conduit->calls('feed.query_id')],
    [$cursor, $cursor + 1, $cursor + 2],
    'tried PHAB_FEED_MAX_RETRIES (3) times'
  );
  is($env->cursor('feed'), $cursor, 'cursor unchanged');
}

# Other feed.query_id failures throw at once and leave the cursor alone
foreach my $case (
  ['Conduit error', conduit_error('ERR-CONDUIT-CORE', 'Database is read-only')],
  ['HTTP 500',      http_error(500)],
  ['HTTP 503',      http_error(503)],
  ['non-JSON body', invalid_json()],
  ['network error', network_error('Connection refused')],
  )
{
  my ($name, $reply) = @$case;
  my $cursor = start_scenario();
  story(object_phid => 'PHID-TASK-unseen');
  $conduit->queue('feed.query_id' => $reply);
  my $error = with_typed_errors(sub { run_feed() });
  ok($error, "$name: feed_query throws");
  is($conduit->call_count('feed.query_id'), 1,       "$name: not retried");
  is($env->cursor('feed'),                  $cursor, "$name: cursor unchanged");
}

# A story that fails is rolled back and the cursor stops before it
{
  my $bug = $env->bug;
  my $raw = revision(bug_id => $bug->id);
  start_scenario();
  my $before = story(object_phid => 'PHID-TASK-before');
  my $bad    = story(object_phid => $raw->{phid}, text => updated_text($raw));
  my $after  = story(object_phid => 'PHID-TASK-after');

  $conduit->on(
    'differential.revision.edit' => sub {
      my ($params, $c) = @_;
      return conduit_error('ERR-CONDUIT-CORE', 'Edit rejected')
        if $params->{objectIdentifier} eq $raw->{phid};
      return $c->default_reply('differential.revision.edit', $params);
    }
  );

  ok(run_feed(), 'feed_query throws when a story fails');
  is($env->cursor('feed'), $before->{id},
    'cursor stops before the failing story');
  is(scalar(phab_attachments($bug->id)),
    0, 'BMO changes for the failing story are rolled back');

  ok(run_feed(), 'the failing story fails again on the next run');

TODO: {
    local $TODO
      = 'feed_query has no per-story error handling; one bad story stalls the feed';
    cmp_ok($env->cursor('feed') // 0,
      '>=', $after->{id},
      'stories after a persistently failing story are still processed');
  }

  $conduit->off('differential.revision.edit');
  ok(!run_feed(), 'feed resumes once the story can be processed');
  is($env->cursor('feed'), $after->{id}, 'cursor catches up');
}

$env->fresh_request;
$env->finish;
done_testing;
