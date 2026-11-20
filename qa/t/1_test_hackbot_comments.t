# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 2086124: Hackbot comments start with a front matter block that links them
# to the run that wrote them. hackbot-api posts them through REST, so they are
# posted the same way here, and the bug page is checked in the browser: the
# block is hidden, the header shows the agent and a link to the run, the
# agent's comment tag is hidden, and quoting the comment leaves the block out.
# The same block typed by anyone else is an ordinary comment.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use QA::Util;
use QA::Tests qw(create_bug_fields);
use Test::More;
use Test::Mojo;

my ($sel, $config) = get_selenium();

my $rest = "$config->{browser_url}/rest";
my $t    = Test::Mojo->new;

sub api_key_header {
  my ($user) = @_;
  return {'X-Bugzilla-API-Key' => $config->{"${user}_user_api_key"}};
}

my $agent = 'frontend-triage';

# Comment tags are case-insensitive, so the agent's tag may differ in case.
my $agent_tag = 'Frontend-Triage';

# Matches the agent only if a tag were read as a pattern ('.' is any character).
my $lookalike_tag = 'frontend.triage';
my $run           = 'e2e-run-1';
my $url           = "https://hackbot.example/runs/$run";
my $block         = join("\n",
  '---', 'hackbot:', "  run: $run",
  '  action: 3f2a9c1e',
  "  agent: $agent",
  "  url: $url", '---', '', '');

# Turn the integration on for the Hackbot test account, through the UI.
log_in($sel, $config, 'admin');
set_parameters(
  $sel,
  {
    'Hackbot' =>
      {'hackbot_user' => {type => 'text', value => $config->{hackbot_user_login}},}
  }
);

my %bug = %{create_bug_fields($config)};
delete $bug{creator};
$t->post_ok(
  "$rest/bug" => api_key_header('admin') => json => {
    %bug,
    summary     => 'Hackbot comment metadata',
    description => 'A bug for Hackbot to comment on',
  }
)->status_is(200, 'The bug is filed');
my $bug_id = $t->tx->res->json('/id');

sub add_comment {
  my ($user, $text) = @_;
  $t->post_ok("$rest/bug/$bug_id/comment" => api_key_header($user) => json =>
      {comment => $text, is_markdown => 1})->status_is(201, "$user adds a comment");
  return $t->tx->res->json('/id');
}

# The order matters: the field change comes right after the Hackbot comment,
# so a change header that picked up the comment before it would show the badge.
my $forged_id  = add_comment('unprivileged', "${block}Typed by someone else.");
my $plain_id   = add_comment('hackbot',      'A plain Hackbot comment.');
my $hackbot_id = add_comment('hackbot', "${block}Triage result: front end.");

$t->put_ok(
  "$rest/bug/comment/$hackbot_id/tags" => api_key_header('admin') => json => {
    comment_id => $hackbot_id,
    add        => [$agent_tag, $lookalike_tag, 'needs-review']
  }
)->status_is(200, 'The comment is tagged');
$t->put_ok("$rest/bug/$bug_id" => api_key_header('admin') => json =>
    {whiteboard => 'hackbot-e2e'})
  ->status_is(200, 'A field is changed with no comment');

# What the page shows for a comment, read in one go.
sub comment_view {
  my ($comment_id) = @_;
  return $sel->driver->execute_script(<<"JS");
const set = document.querySelector('.comment[data-id="$comment_id"]').closest('.change-set');
const meta = set.querySelector('.hackbot-meta');
const run = meta && meta.querySelector('.run');
return {
  text: set.querySelector('.comment-text').innerText.trim(),
  agent: meta ? meta.querySelector('.agent').textContent.trim() : '',
  run: run ? run.getAttribute('href') : '',
  badge: [...set.querySelectorAll('.change-author .user-role')]
    .some(role => role.textContent.trim() === 'AI'),
  tags: Object.fromEntries([...set.querySelectorAll('.comment-tag')]
    .map(tag => [tag.dataset.tag, getComputedStyle(tag).display !== 'none'])),
};
JS
}

# Poll the page until a JavaScript expression is true.
sub wait_for_js_ok {
  my ($expression, $name) = @_;
  for (1 .. 20) {
    return ok(1, $name) if $sel->driver->execute_script("return !!($expression)");
    sleep 1;
  }
  return ok(0, $name);
}

go_to_bug($sel, $bug_id, 1);

my $view = comment_view($hackbot_id);
is($view->{text},  'Triage result: front end.', 'The block is hidden');
is($view->{agent}, $agent,                      'The header names the agent');
is($view->{run},   $url,                        'The header links to the run');
ok($view->{badge},                'The author has the AI badge');
ok(!$view->{tags}{$agent_tag},    'The agent tag is hidden');
ok($view->{tags}{'needs-review'}, 'Other tags are shown');
ok($view->{tags}{$lookalike_tag},
  'A tag that only looks like the agent is shown');

$view = comment_view($forged_id);
like(
  $view->{text},
  qr/hackbot:.*run: $run/s,
  "Another user's block is shown as text"
);
is($view->{agent}, '', '... with no agent in the header');
ok(!$view->{badge}, '... and no AI badge');

$view = comment_view($plain_id);
is(
  $view->{text},
  'A plain Hackbot comment.',
  'A plain Hackbot comment is unchanged'
);
is($view->{agent}, '', '... with no agent in the header');

ok(
  !$sel->driver->execute_script(<<'JS'),
return [...document.querySelectorAll('.change-set')]
  .filter(set => !set.querySelector('.comment'))
  .some(set => [...set.querySelectorAll('.change-author .user-role')]
    .some(role => role.textContent.trim() === 'AI'));
JS
  'A field change has no AI badge'
);

# Quoting the comment leaves the block out.
$sel->js_click_ok(
  qq{//button[contains(\@class, "reply-btn") and \@data-id="$hackbot_id"]},
  'Reply to the Hackbot comment');
wait_for_js_ok(
  q{document.querySelector('#comment').value.includes('> Triage result: front end.')},
  'The reply quotes the comment'
);
unlike(
  $sel->driver->execute_script(
    q{return document.querySelector('#comment').value}),
  qr/hackbot:|run: $run/,
  'The reply has no block'
);
$sel->driver->execute_script(q{document.querySelector('#comment').value = ''});

# Changing the tags renders them again, and the agent tag stays hidden.
my $tags = qq{.comment[data-id="$hackbot_id"] .comment-tag};
$sel->js_click_ok(
  qq{//button[contains(\@class, "tag-btn") and \@data-id="$hackbot_id"]},
  'Open the tag editor');
$sel->type_ok('ctag-add', 'e2e-added', 'Type a new tag');
$sel->js_click_ok('ctag-save', 'Save the tag');
wait_for_js_ok(qq{document.querySelector('$tags\[data-tag="e2e-added"]')},
  'The new tag is shown');
$view = comment_view($hackbot_id);
ok($view->{tags}{'e2e-added'}, 'The new tag is visible');
ok(!$view->{tags}{$agent_tag}, 'The agent tag is still hidden');

$sel->js_click_ok(
  qq{//div[contains(\@class, "comment") and \@data-id="$hackbot_id"]}
    . q{//span[@data-tag="needs-review"]/a[contains(@class, "remove")]},
  'Remove a tag'
);
wait_for_js_ok(qq{!document.querySelector('$tags\[data-tag="needs-review"]')},
  'The tag is removed');
ok(!comment_view($hackbot_id)->{tags}{$agent_tag},
  'The agent tag is still hidden');

# Turn the integration off again: the block is shown as it is stored.
set_parameters($sel,
  {'Hackbot' => {'hackbot_user' => {type => 'text', value => ''}}});
go_to_bug($sel, $bug_id, 1);
$view = comment_view($hackbot_id);
like($view->{text}, qr/hackbot:.*agent: $agent/s, 'Off: the block is shown');
is($view->{agent}, '', 'Off: no agent in the header');

logout($sel);

done_testing();
