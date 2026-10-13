#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
#
# Both github webhook endpoints perform their writes as
# github-automation@bmo.tld, an account elevated into every group, while the bug
# ids they act on come from attacker-influenced request data. push_comment scopes
# referenced bugs to the signing bot's visibility; pull_request keeps its target
# public-only and scopes only stale-attachment cleanup to bot visibility. These
# tests pin those boundaries:
#
#   * push_comment must not comment on, resolve, or even acknowledge a bug the
#     signing bot cannot see;
#   * pull_request must not obsolete -- or comment on -- an existing pull
#     request attachment sitting on a bug the signing bot cannot see.
use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}         = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE}     = 1;
  $ENV{BUGZILLA_ALLOW_INSECURE_HTTP} = 1;
}

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams (
  github_push_comment_enabled => 1,
  github_pr_linking_enabled   => 1,
  github_pr_signature_secret  => '',
);
use Bugzilla::Test::Util qw(create_bug create_user issue_api_key);

use Bugzilla::Attachment;
use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::User;

use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON  qw(encode_json);
use Test2::V0;
use Test::Mojo;

# super_user() resolves the 'automation@bmo.tld' account, which the mock DB
# does not ship. Without it we would silently run as the anonymous default
# user, and creating the fixture bugs below would die with login_required.
create_user('automation@bmo.tld', '*');
Bugzilla->set_user(Bugzilla::User->super_user);
my $dbh = Bugzilla->dbh;

# ---------------------------------------------------------------------------
# Fixtures: the impersonated automation account, a webhook bot with a signing
# key, and a public and a group-restricted bug.
# ---------------------------------------------------------------------------

# push_comment does Bugzilla::User->check on this account before writing.
create_user('github-automation@bmo.tld', '*');

my $BOT_KEY = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd';    # varchar(40)
my $bot     = create_user('webhook-bot@bmo.test', '*');
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, ?)', undef, $bot->id,
  Bugzilla::Group->new({name => 'github-webhook-bot'})->id, GRANT_DIRECT
);
issue_api_key('webhook-bot@bmo.test', $BOT_KEY);

my $sec_group = Bugzilla::Group->create({
  name        => 'webhook-visibility-test-sec',
  description => 'Group the webhook bot is not a member of',
  isbuggroup  => 1,
});

sub make_bug {
  my ($desc, $group_id) = @_;
  my $bug = create_bug(
    short_desc  => $desc,
    comment     => 'Bug for the push_comment visibility gate tests',
    bug_type    => 'defect',
    assigned_to => 'nobody@mozilla.org',
  );

  # Inserted directly so the bug lands in the group regardless of the product's
  # group controls -- only the resulting visibility matters here.
  $dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
    undef, $bug->id, $group_id)
    if $group_id;

  return $bug->id;
}

my $public_bug  = make_bug('Public bug the webhook bot can see');
my $private_bug = make_bug('Restricted bug the webhook bot cannot see',
  $sec_group->id);

# pull_request fixtures. Every bug here has to be created before the first
# request below: creating a bug runs BMO's object_end_of_create hook, which
# calls remote_ip(), and that needs a live Mojo transaction. Once a request has
# completed, the controller left in the request cache has no transaction and
# remote_ip() dies.
#
# A group of its own, so this section does not depend on the membership the
# push_comment tests grant partway through.
my $pr_group = Bugzilla::Group->create({
  name        => 'webhook-visibility-test-pr-sec',
  description => 'Group the webhook bot is not a member of',
  isbuggroup  => 1,
});

# A second group, for the target-side test at the bottom of the file. Kept
# separate from $pr_group so that test does not depend on the membership the
# cleanup-pass tests grant partway through.
my $pr_target_group = Bugzilla::Group->create({
  name        => 'webhook-visibility-test-pr-target',
  description => 'Group only the webhook bot is granted',
  isbuggroup  => 1,
});

my $PR_URL = 'https://github.com/x/y/pull/42';

my $pr_private_bug
  = make_bug('Restricted bug holding a stale PR attachment', $pr_group->id);
my $pr_bug_one = make_bug('Public bug the PR is attached to first');
my $pr_bug_two = make_bug('Public bug the PR is attached to second');
my $pr_restricted_target
  = make_bug('Restricted bug named in a pull request title',
  $pr_target_group->id);

# The stale attachment the cleanup pass will try to obsolete. Attachment->match()
# keys off the mimetype plus the filename the endpoint derives from the repo name
# and PR number, so these have to line up with the payload posted below.
my $pr_stale_attach_id = Bugzilla::Attachment->create({
  bug         => Bugzilla::Bug->check({id => $pr_private_bug}),
  creation_ts => $dbh->selectrow_array('SELECT NOW()'),
  data        => $PR_URL,
  description => '[x/y] Some pull request (#42)',
  filename    => 'github-x_y-42-url.txt',
  ispatch     => 0,
  isprivate   => 0,
  mimetype    => 'text/x-github-pull-request',
})->id;

# Sanity check the fixture itself: without it the "denied" cases below would
# pass for the wrong reason.
my $bot_user = Bugzilla::User->new({id => $bot->id});
ok($bot_user->can_see_bug($public_bug),   'bot can see the public bug');
ok(!$bot_user->can_see_bug($private_bug), 'bot cannot see the restricted bug');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

my $t = Test::Mojo->new('Bugzilla::App');

# 'x/y' rather than mozilla-mobile/firefox-android so the milestone and status
# flag paths (which call out to the product-versions API) stay out of the way.
sub push_payload {
  my (@bug_ids) = @_;
  return {
    ref        => 'refs/heads/main',
    repository => {full_name => 'x/y', default_branch => 'main'},
    commits    => [
      map {
        {
          author  => {name => 'Foo Bar', username => 'foobar'},
          url     => "https://github.com/x/y/commit/abc$_",
          message => "Bug $_ - land a fix",
        }
      } @bug_ids
    ],
  };
}

# Sign and send the exact bytes, since _verify_signature HMACs the raw body.
# no-qe-verify=1 because the qe-verify flag type does not exist in the mock DB.
sub post_push {
  my ($payload) = @_;
  my $body = encode_json($payload);
  return $t->post_ok(
    '/rest/github/push_comment?no-qe-verify=1',
    {
      'X-Hub-Signature-256' => 'sha256=' . hmac_sha256_hex($body, $BOT_KEY),
      'X-GitHub-Event'      => 'push',
      'Content-Type'        => 'application/json',
    },
    $body
  );
}

sub bug_status {
  my ($bug_id) = @_;
  return scalar Bugzilla->dbh->selectrow_array('SELECT bug_status FROM bugs WHERE bug_id = ?',
    undef, $bug_id);
}

sub comment_count {
  my ($bug_id) = @_;
  return scalar Bugzilla->dbh->selectrow_array(
    'SELECT COUNT(*) FROM longdescs WHERE bug_id = ?', undef, $bug_id);
}

# The rendered message is wrapped by the template, so match across whitespace.
my $BUG_NOT_FOUND = qr/did\s+not\s+contain\s+a\s+valid/;

# ---------------------------------------------------------------------------
# A bug the signing bot can see is processed exactly as before -- the gate must
# not break the normal case.
# ---------------------------------------------------------------------------
post_push(push_payload($public_bug))->status_is(200)
  ->json_is('/error' => 0)
  ->json_has("/bugs/$public_bug/id", 'visible bug is commented on');

is(bug_status($public_bug), 'RESOLVED', 'visible bug was resolved');

# The write still happens as the elevated automation account.
is(
  scalar Bugzilla->dbh->selectrow_array(
    'SELECT p.login_name FROM longdescs l JOIN profiles p ON p.userid = l.who
      WHERE l.bug_id = ? ORDER BY l.comment_id DESC LIMIT 1', undef, $public_bug
  ),
  'github-automation@bmo.tld',
  'comment is still attributed to the automation account'
);

# ---------------------------------------------------------------------------
# A bug the signing bot cannot see is left completely alone, and the response
# is the same one an unparseable bug id produces -- so it cannot be used as an
# oracle for the existence of confidential bug ids.
# ---------------------------------------------------------------------------
my $private_comments = comment_count($private_bug);
my $private_status   = bug_status($private_bug);

my $denied = post_push(push_payload($private_bug));
$denied->status_is(400)->json_is('/error' => 1);
$denied->json_like('/message' => $BUG_NOT_FOUND, 'invisible bug is rejected');
$denied->json_hasnt("/bugs/$private_bug",
  'response does not name the invisible bug');

is(comment_count($private_bug), $private_comments,
  'no comment was added to the invisible bug');
is(bug_status($private_bug), $private_status,
  'invisible bug status is unchanged');

# ---------------------------------------------------------------------------
# One push touching both bugs: the visible one is processed, the invisible one
# is dropped. A single unreadable bug id must not fail the whole delivery, or
# GitHub would retry it forever.
# ---------------------------------------------------------------------------
$private_comments = comment_count($private_bug);

# Reopen so there is an observable change to make on the public bug.
Bugzilla->dbh->do('UPDATE bugs SET bug_status = ?, resolution = ? WHERE bug_id = ?',
  undef, 'CONFIRMED', '', $public_bug);

my $mixed = post_push(push_payload($public_bug, $private_bug));
$mixed->status_is(200)->json_is('/error' => 0);
$mixed->json_has("/bugs/$public_bug/id", 'mixed push: visible bug is processed');
$mixed->json_hasnt("/bugs/$private_bug", 'mixed push: invisible bug is dropped');

is(comment_count($private_bug), $private_comments,
  'mixed push left the invisible bug untouched');
is(bug_status($public_bug), 'RESOLVED', 'mixed push resolved the visible bug');

# ---------------------------------------------------------------------------
# The gate is scoped to the signing bot, not hardcoded to public bugs: granting
# the bot the group makes the same request succeed. This is how an operator
# deliberately gives a webhook reach into confidential bugs.
# ---------------------------------------------------------------------------
Bugzilla->dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, ?)', undef, $bot->id, $sec_group->id, GRANT_DIRECT
);
Bugzilla->memcached->clear_all;

post_push(push_payload($private_bug))->status_is(200)
  ->json_is('/error' => 0)
  ->json_has("/bugs/$private_bug/id",
  'bot in the group can now reach the restricted bug');

is(bug_status($private_bug), 'RESOLVED',
  'restricted bug was resolved once the bot had access');

# ---------------------------------------------------------------------------
# pull_request: the cleanup pass that obsoletes the same pull request
# attachment on other bugs runs as the all-groups automation account, so it is
# gated on the signing bot too. A bug the bot cannot see must keep its
# attachment and gain no comment.
# ---------------------------------------------------------------------------
ok(!Bugzilla::User->new({id => $bot->id})->can_see_bug($pr_private_bug),
  'bot cannot see the bug holding the stale PR attachment');

sub post_pull_request {
  my ($bug_id) = @_;
  my $body = encode_json({
    action       => 'opened',
    repository   => {full_name => 'x/y'},
    pull_request =>
      {html_url => $PR_URL, title => "Bug $bug_id - do a thing", number => 42},
  });
  return $t->post_ok(
    '/rest/github/pull_request',
    {
      'X-Hub-Signature-256' => 'sha256=' . hmac_sha256_hex($body, $BOT_KEY),
      'X-GitHub-Event'      => 'pull_request',
      'Content-Type'        => 'application/json',
    },
    $body
  );
}

sub is_obsolete {
  my ($attach_id) = @_;
  return scalar Bugzilla->dbh->selectrow_array(
    'SELECT isobsolete FROM attachments WHERE attach_id = ?', undef, $attach_id);
}

sub pr_attachment_count {
  my ($bug_id) = @_;
  return scalar Bugzilla->dbh->selectrow_array(
    'SELECT COUNT(*) FROM attachments WHERE bug_id = ? AND mimetype = ?',
    undef, $bug_id, 'text/x-github-pull-request');
}

my $pr_private_comments = comment_count($pr_private_bug);

post_pull_request($pr_bug_one)->status_is(200)->json_is('/error' => 0);

ok(!is_obsolete($pr_stale_attach_id),
  'attachment on the invisible bug was not obsoleted');
is(comment_count($pr_private_bug), $pr_private_comments,
  'no "moved to bug" comment was added to the invisible bug');

# Sanity check that the request did its normal work, otherwise the assertions
# above would pass even if the endpoint had bailed out before the cleanup pass.
is(pr_attachment_count($pr_bug_one), 1,
  'the pull request was still attached to the visible bug');

# ---------------------------------------------------------------------------
# As with push_comment, the gate follows the signing bot: once the bot can see
# the bug, the same cleanup pass does obsolete the stale attachment.
# ---------------------------------------------------------------------------
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, ?)', undef, $bot->id, $pr_group->id, GRANT_DIRECT
);
Bugzilla->memcached->clear_all;

post_pull_request($pr_bug_two)->status_is(200)->json_is('/error' => 0);

ok(is_obsolete($pr_stale_attach_id),
  'attachment is obsoleted once the bot can see the bug');
cmp_ok(comment_count($pr_private_bug), '>', $pr_private_comments,
  'the "moved to bug" comment is added once the bot can see the bug');

# ---------------------------------------------------------------------------
# The two visibility gates in pull_request are deliberately asymmetric, and
# this pins the half the tests above do not reach.
#
# The *cleanup* pass (tested above) is gated on the signing bot, because it
# touches bugs the request never named. The *target* bug -- the one in the pull
# request title -- is gated on Bugzilla->user, which is anonymous on /rest, so
# a pull request can only ever be attached to a publicly visible bug. Widening
# that to the signing bot would let a GitHub PR title pull a confidential bug
# into an externally-visible attachment, so it is not a check the bot's group
# membership should be able to unlock.
#
# Granting the bot the group is the point: every assertion below must hold even
# though the signing bot can see the bug perfectly well.
# ---------------------------------------------------------------------------
$dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
   VALUES (?, ?, 0, ?)', undef, $bot->id, $pr_target_group->id, GRANT_DIRECT
);
Bugzilla->memcached->clear_all;

ok(Bugzilla::User->new({id => $bot->id})->can_see_bug($pr_restricted_target),
  'signing bot can see the restricted target bug');

my $target_comments = comment_count($pr_restricted_target);

my $target = post_pull_request($pr_restricted_target);
$target->status_is(200)->json_is('/error' => 1);
$target->json_like('/message' => qr/not\s+publicly\s+visible/,
  'restricted target bug is rejected even though the bot can see it');

is(pr_attachment_count($pr_restricted_target),
  0, 'no pull request was attached to the restricted target bug');
is(comment_count($pr_restricted_target),
  $target_comments, 'no comment was added to the restricted target bug');

# ---------------------------------------------------------------------------
# Disabling the bot account must disable its webhook keys too. _verify_signature
# queries user_api_keys directly rather than going through Bugzilla::Auth, so it
# has to apply the is_enabled check itself -- otherwise the usual way to shut
# off a compromised or retired bot (disable the account) would leave every one
# of its keys signing valid webhooks. Kept last because it makes $BOT_KEY dead.
# ---------------------------------------------------------------------------
my $before_comments = comment_count($public_bug);

$dbh->do('UPDATE profiles SET is_enabled = 0, disabledtext = ? WHERE userid = ?',
  undef, 'retired bot', $bot->id);
Bugzilla->memcached->clear_all;

my $disabled = post_push(push_payload($public_bug));
$disabled->status_is(400)->json_is('/error' => 1);
$disabled->json_like('/message' => qr/signature/i,
  'key of a disabled bot no longer authenticates');

is(comment_count($public_bug), $before_comments,
  'disabled bot request made no change to the bug');

done_testing();
