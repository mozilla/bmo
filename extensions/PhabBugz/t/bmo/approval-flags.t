#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Util::set_attachment_approval_flags: the approval-mozilla-<repo>
# flags PhabBugz sets on revision attachments for uplift repositories.
#
# scripts/generate_bmo_data.pl seeds approval-mozilla-{beta,release,esr140}
# for Firefox :: General only, and approval-mozilla-esr115 disabled. A bug
# in any other product or component therefore reproduces the production
# failure where the flag is not enabled where the bug lives.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Attachment;
use Bugzilla::FlagType;
use Mojo::JSON qw(false);
use Storable   qw(dclone);
use Test::More;
use Test2::Tools::Exception qw(lives);

use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Feed;
use Bugzilla::Extension::PhabBugz::Revision;
use Bugzilla::Extension::PhabBugz::User;
use Bugzilla::Extension::PhabBugz::Util qw(
  create_revision_attachment
  is_attachment_phab_revision
  set_attachment_approval_flags
  set_phab_user
);
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;
my $dbh     = Bugzilla->dbh;
my $feed    = Bugzilla::Extension::PhabBugz::Feed->new;

# The flag types come from scripts/generate_bmo_data.pl. Skip only this file
# if they are missing: BAIL_OUT would stop every other t/bmo test too.
my @missing = grep { !Bugzilla::FlagType->new({name => $_}) }
  map {"approval-mozilla-$_"} qw(beta release esr140 esr115);
if (@missing) {
  $env->teardown;
  plan skip_all => "@missing not seeded; rerun generate_bmo_data.pl";
}
ok(!Bugzilla::FlagType->new({name => 'approval-mozilla-esr115'})->is_active,
  'approval-mozilla-esr115 is disabled');

my $author      = $env->bmo_user('author');
my $author_phab = $env->link_user($author, username => 'phabtest-author');
my $relman      = $env->bmo_user('relman');
my $relman_phab = $env->link_user($relman, username => 'phabtest-relman');
my $dev         = $env->bmo_user('dev');
my $dev_phab    = $env->link_user($dev, username => 'phabtest-dev');

$conduit->add_project(
  project_obj(name => 'release-managers', members => [$relman_phab->{phid}]));
my $uplift = $conduit->add_project(project_obj(name => 'uplift'));
my %repo   = map {
  $_ => $conduit->add_repository(
    repository_obj(short_name => $_, projects => [$uplift->{phid}]))
} qw(firefox-beta firefox-release firefox-esr140 firefox-esr115 firefox-unknown);

my ($timestamp) = $dbh->selectrow_array('SELECT NOW()');

# A revision on a new bug, with its BMO attachment.
sub revision_attachment {
  my (%args) = @_;
  my $bug = $env->bug(
    product   => $args{product}   // 'Firefox',
    component => $args{component} // 'General',
  );
  my $raw = revision_obj(
    bug_id          => $bug->id,
    author_phid     => $author_phab->{phid},
    repository_phid => $repo{$args{repo} // 'firefox-beta'}{phid},
    status          => $args{status}    // 'needs-review',
    reviewers       => $args{reviewers} // [],
  );
  my $revision = $conduit->load_revision($raw);
  my $attachment
    = create_revision_attachment($bug, $revision, $timestamp, $author);
  $bug->update($timestamp);
  return ($revision, $attachment, $raw);
}

# Call set_attachment_approval_flags the way the feed does (as phab-bot)
# and save the attachment.
sub apply_flags {
  my ($attachment, $revision, $changer_phab, $is_new) = @_;
  my $changer = Bugzilla::Extension::PhabBugz::User->new(dclone($changer_phab));
  my $restore = set_phab_user();
  set_attachment_approval_flags($attachment, $revision, $changer, $is_new);
  $attachment->update($timestamp);
}

sub reload {
  my ($revision) = @_;
  return Bugzilla::Extension::PhabBugz::Revision->new_from_query(
    {phids => [$revision->phid]});
}

# {flag name => status} of the approval flags on an attachment
sub approval_flags {
  my ($attachment) = @_;
  my $fresh = Bugzilla::Attachment->new($attachment->id);
  return {map { $_->name => $_->status }
    grep { $_->name =~ /^approval-mozilla-/ } @{$fresh->flags}};
}

# A new revision requests approval
{
  my ($revision, $attachment, $raw) = revision_attachment();
  apply_flags($attachment, $revision, $author_phab, 1);
  is_deeply(
    approval_flags($attachment),
    {'approval-mozilla-beta' => '?'},
    'new revision on firefox-beta requests approval-mozilla-beta'
  );
  my ($flag) = grep { $_->name eq 'approval-mozilla-beta' }
    @{Bugzilla::Attachment->new($attachment->id)->flags};
  is($flag->setter->id, $author->id, 'requested by the revision author');

  # A release manager accepting the revision grants it
  $raw->{attachments}{reviewers}{reviewers} = [{
    reviewerPHID => $relman_phab->{phid},
    status       => 'accepted',
    isBlocking   => false,
    actorPHID    => $relman_phab->{phid}
  }];
  apply_flags($attachment, reload($revision), $relman_phab, 0);
  is_deeply(
    approval_flags($attachment),
    {'approval-mozilla-beta' => '+'},
    'release manager acceptance sets approval-mozilla-beta+'
  );
}

# Other reviewers cannot grant approval
{
  my ($revision, $attachment)
    = revision_attachment(
    reviewers => [{phid => $dev_phab->{phid}, status => 'accepted'}]);
  apply_flags($attachment, $revision, $author_phab, 1);
  apply_flags($attachment, $revision, $dev_phab,    0);
  is_deeply(
    approval_flags($attachment),
    {'approval-mozilla-beta' => '?'},
    'acceptance by a non release manager leaves the request alone'
  );

  my ($fresh_revision, $fresh_attachment)
    = revision_attachment(
    reviewers => [{phid => $dev_phab->{phid}, status => 'accepted'}]);
  apply_flags($fresh_attachment, $fresh_revision, $dev_phab, 0);
  is_deeply(approval_flags($fresh_attachment),
    {}, 'a non release manager cannot create a + flag');

  my ($rejected_revision, $rejected_attachment)
    = revision_attachment(
    reviewers => [{phid => $relman_phab->{phid}, status => 'rejected'}]);
  apply_flags($rejected_attachment, $rejected_revision, $relman_phab, 0);
  is_deeply(approval_flags($rejected_attachment),
    {}, 'a rejecting review has no flag mapping and changes nothing');

  my ($other_revision, $other_attachment)
    = revision_attachment(
    reviewers => [{phid => $relman_phab->{phid}, status => 'accepted'}]);
  apply_flags($other_attachment, $other_revision, $dev_phab, 0);
  is_deeply(approval_flags($other_attachment),
    {}, 'a changer who is not a reviewer changes nothing');
}

# Revision status mapping for new revisions
{
  my ($revision, $attachment) = revision_attachment(status => 'needs-revision');
  apply_flags($attachment, $revision, $author_phab, 1);
  is_deeply(
    approval_flags($attachment),
    {'approval-mozilla-beta' => '-'},
    'new revision in needs-revision creates a - flag (no release manager check)'
  );

  my ($planned, $planned_attachment, $planned_raw) = revision_attachment();
  apply_flags($planned_attachment, $planned, $author_phab, 1);
  $planned_raw->{fields}{status}{value} = 'changes-planned';
  apply_flags($planned_attachment, reload($planned), $author_phab, 1);
  is_deeply(approval_flags($planned_attachment),
    {}, 'changes-planned clears the pending request');

  my ($fresh_planned, $fresh_planned_attachment)
    = revision_attachment(status => 'changes-planned');
  apply_flags($fresh_planned_attachment, $fresh_planned, $author_phab, 1);
  is_deeply(approval_flags($fresh_planned_attachment),
    {}, 'changes-planned never creates a flag');
}

# Repository name -> flag name
{
  my ($release, $release_attachment)
    = revision_attachment(repo => 'firefox-release');
  apply_flags($release_attachment, $release, $author_phab, 1);
  is_deeply(
    approval_flags($release_attachment),
    {'approval-mozilla-release' => '?'},
    'firefox-release maps to approval-mozilla-release'
  );

  my ($esr, $esr_attachment) = revision_attachment(repo => 'firefox-esr140');
  apply_flags($esr_attachment, $esr, $author_phab, 1);
  is_deeply(
    approval_flags($esr_attachment),
    {'approval-mozilla-esr140' => '?'},
    'firefox-esr140 maps to approval-mozilla-esr140'
  );

  my ($disabled, $disabled_attachment)
    = revision_attachment(repo => 'firefox-esr115');
  ok(
    lives { apply_flags($disabled_attachment, $disabled, $author_phab, 1) },
    'a disabled approval flag does not fail'
  );
  is_deeply(approval_flags($disabled_attachment),
    {}, 'disabled approval flag is skipped');

  my ($unknown, $unknown_attachment)
    = revision_attachment(repo => 'firefox-unknown');
  ok(
    lives { apply_flags($unknown_attachment, $unknown, $author_phab, 1) },
    'a repository without an approval flag type does not fail'
  );
  is_deeply(approval_flags($unknown_attachment), {}, 'no flag set');
}

# The flag is not enabled for the bug's product or component
foreach my $case (
  ['product',   'bugzilla.mozilla.org', 'General'],
  ['component', 'Firefox',              'Installer'],
  )
{
  my ($what, $product, $component) = @$case;
  my ($revision, $attachment)
    = revision_attachment(product => $product, component => $component);
  my $error = throws_error(
    sub { apply_flags($attachment, $revision, $author_phab, 1) },
    'bugzilla.code.invalid_flag_association',
    "approval flag not enabled for the $what ($product :: $component) throws"
  );
  is($error && $error->info->{attach_id},
    $attachment->id, 'error names the attachment')
    if $error;
}

# Through the feed daemon
{
  my $last_story_id = 8_000_000;
  my $story         = sub {
    my ($raw, $author_phid, $text) = @_;
    return $conduit->add_story(feed_story(
      id          => ++$last_story_id,
      author_phid => $author_phid,
      object_phid => $raw->{phid},
      text        => $text,
    ));
  };
  my $run
    = sub { with_typed_errors(sub { $env->run_sync(sub { $feed->feed_query }) }) };
  my $attachments = sub {
    my ($bug) = @_;
    return [grep { is_attachment_phab_revision($_) }
        @{Bugzilla::Bug->new($bug->id)->attachments}];
  };

  # New revision, then a release manager accepts it
  my $bug = $env->bug;
  my $raw = $conduit->add_revision(revision_obj(
    bug_id          => $bug->id,
    author_phid     => $author_phab->{phid},
    repository_phid => $repo{'firefox-beta'}{phid},
  ));
  $env->save_cursor('feed', $last_story_id);
  $story->(
    $raw, $author_phab->{phid}, "phabtest-author created D$raw->{id}: uplift."
  );
  ok(!$run->(), 'feed: new uplift revision');
  my ($attachment) = @{$attachments->($bug)};
  is_deeply(
    $attachment ? approval_flags($attachment) : {},
    {'approval-mozilla-beta' => '?'},
    'feed: approval requested'
  );

  $raw->{attachments}{reviewers}{reviewers} = [{
    reviewerPHID => $relman_phab->{phid},
    status       => 'accepted',
    isBlocking   => false,
    actorPHID    => $relman_phab->{phid}
  }];
  $story->($raw, $relman_phab->{phid}, "phabtest-relman accepted D$raw->{id}.");
  ok(!$run->(), 'feed: release manager accepts');
  is_deeply(
    $attachment ? approval_flags($attachment) : {},
    {'approval-mozilla-beta' => '+'},
    'feed: approval granted'
  );

  # Revision on a bug where the approval flag is not enabled
  foreach my $case (
    ['product',   'bugzilla.mozilla.org', 'General'],
    ['component', 'Firefox',              'Installer'],
    )
  {
    my ($what, $product, $component) = @$case;
    my $other = $env->bug(product => $product, component => $component);
    my $bad   = $conduit->add_revision(revision_obj(
      bug_id          => $other->id,
      author_phid     => $author_phab->{phid},
      repository_phid => $repo{'firefox-beta'}{phid},
    ));
    my $cursor = $last_story_id;
    $env->save_cursor('feed', $cursor);
    $story->(
      $bad, $author_phab->{phid}, "phabtest-author created D$bad->{id}: uplift."
    );

    my $error = $run->();
    is(
      ref $error && $error->type,
      'bugzilla.code.invalid_flag_association',
      "feed: flag not enabled for the $what fails the story"
    );
    is($env->cursor('feed'), $cursor, "feed ($what): cursor not advanced");
    is(scalar @{$attachments->($other)},
      0, "feed ($what): revision attachment rolled back");
    is($conduit->call_count('differential.revision.edit'),
      0, "feed ($what): revision not updated");

  TODO: {
      local $TODO
        = 'a missing approval flag fails the whole story instead of being skipped';
      $run->();
      is(scalar @{$attachments->($other)},
        1, "feed ($what): revision still synced to the bug without the flag");
      cmp_ok($env->cursor('feed') // 0,
        '>', $cursor, "feed ($what): cursor moves past the story");
    }
  }
}

$env->fresh_request;
$env->finish;
done_testing;
