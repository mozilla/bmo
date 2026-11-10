# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The @mention autocomplete in the bug comment editor
# (extensions/Needinfo/web/js/mention-autocomplete.js). /rest/user/suggest is
# stubbed so the test controls exactly which accounts come back, and only the
# client-side logic is exercised: which text triggers a lookup, the filtering
# of the response and inserting the picked nickname. The server side is
# covered by extensions/Needinfo/t/bmo/mention-suggest.t.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Selenium::Remote::WDKeys qw(KEYS);
use Test::More "no_plan";

use QA::Util;

# Replace Bugzilla.API.get with a stub that records the lookup params and
# returns, besides one account that should be offered:
# - the logged-in user, who can't mention themselves,
# - a nickname shared by two accounts (case-insensitively), which
#   _users_for_mentions treats as ambiguous and doesn't resolve,
# - a nickname ending in ".", which _extract_mentions would strip.
use constant STUB_SUGGEST_JS => <<'END';
window.__mention = { params: null };
Bugzilla.API.get = (endpoint, params) => {
  window.__mention.params = params;
  return Promise.resolve({ users: [
    { name: BUGZILLA.user.login, nick: 'selself', real_name: 'Myself' },
    { name: 'one@example.com', nick: 'selone', real_name: 'Sel One' },
    { name: 'dup1@example.com', nick: 'seldup', real_name: 'Sel Dup' },
    { name: 'dup2@example.com', nick: 'SelDup', real_name: 'Sel Dup Too' },
    { name: 'trail@example.com', nick: 'seltrail.', real_name: 'Sel Trail' },
  ] });
};
END

# The nicknames offered, comma-separated, or '' while the list is hidden.
use constant OFFERED_JS => <<'END';
const $list = document.getElementById('mention-autocomplete');
return $list && !$list.hidden
  ? [...$list.querySelectorAll('[itemprop="alternateName"]')].map(($e) => $e.textContent).join(',')
  : '';
END

# Set the comment text with the caret at arguments[1] (default: the end) and
# fire `input` as typing would. Clearing it first closes any open list.
use constant SET_COMMENT_JS => <<'END';
const $comment = document.getElementById('comment');
$comment.focus();
for (const text of ['', arguments[0]]) {
  $comment.value = text;
  const caret = arguments[1] ?? text.length;
  $comment.setSelectionRange(caret, caret);
  $comment.dispatchEvent(new InputEvent('input', { bubbles: true }));
}
END

my ($sel, $config) = get_selenium();
my $driver = $sel->driver;
my $bug_id = $config->{test_bug_1};

log_in($sel, $config, 'editbugs');
go_to_bug($sel, $bug_id);
$driver->execute_script(STUB_SUGGEST_JS);

# Real keystrokes: typing "@sel" looks up nicknames starting with "sel".
$sel->type_ok('comment', 'Hi @sel', 'Type a mention into the comment');

# "@se" may be looked up too if typing is slower than the debounce.
ok(wait_for_js($sel, q{return window.__mention.params?.match === '@sel'}),
  'the lookup is for the typed nickname');
is(wait_for_js($sel, OFFERED_JS),
  '@selone',
  'only the unambiguous, valid nickname of another account is offered');

my $params = $driver->execute_script('return window.__mention.params');
is($params->{bug_id}, $bug_id,
  'the lookup passes the bug id so accounts that cannot see it are left out');

$driver->find_element('comment', 'id')->send_keys(KEYS->{enter});
is($sel->get_value('comment'),
  'Hi @selone ', 'Enter replaces the typed text with the nickname and a space');
is($driver->execute_script(OFFERED_JS), '', 'the list closes after a pick');

# Mentions that _extract_mentions ignores get no suggestions either. Each case
# runs through the same helper as the control, so a hidden list means the
# text was ignored, not that the helper failed.
check_offered('a mention in plain text', 'text @sel', undef, 1);
check_offered('an email address',        'me@sel');
check_offered('a quoted line',           "> quoted\n> \@sel");
check_offered('an inline code span',     '`@sel`', 5);
check_offered('a fenced code block',     "```\n\@sel");
check_offered(
  'a code span in an earlier paragraph does not hide the mention',
  "`code`\n\nmore `code` and \@sel",
  undef, 1
);

# Leave the comment empty so the next page load isn't held up by the draft.
$driver->execute_script(SET_COMMENT_JS, '');
logout($sel);

sub check_offered {
  my ($desc, $text, $caret, $offered) = @_;

  $driver->execute_script(SET_COMMENT_JS, $text, $caret);

  if ($offered) {
    is(wait_for_js($sel, OFFERED_JS), '@selone', "suggestions for $desc");
  }
  else {
    # Longer than the 250ms lookup debounce
    select(undef, undef, undef, 0.6);
    is($driver->execute_script(OFFERED_JS), '', "no suggestions for $desc");
  }
}
