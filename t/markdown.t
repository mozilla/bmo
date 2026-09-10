# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use 5.10.1;
use strict;
use warnings;
use lib qw( . lib local/lib/perl5 );

use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockLocalconfig urlbase => 'http://bmo.test/';
use Bugzilla::Test::MockParams (password_complexity => 'no_constraints');
use Mojo::DOM;
use Bugzilla;
use Test2::V0;

my $have_cmark_gfm = eval {
    require FFI::CheckLib;
    FFI::CheckLib::find_lib(lib => 'cmark-gfm');
};

plan skip_all => "these tests require libcmark-gfm" unless $have_cmark_gfm;

my $parser = Bugzilla->markdown;

is($parser->render_html('# header'), "<h1>header</h1>\n", 'Simple header');

is(
  $parser->render_html('`code snippet`'),
  "<p><code>code snippet</code></p>\n",
  'Simple code snippet'
);

is(
  $parser->render_html('https://www.mozilla.org'),
  "<p><a href=\"https://www.mozilla.org\" rel=\"nofollow noreferrer\" target=\"_blank\">"
    . "https://www.mozilla.org</a></p>\n",
  'Autolink extension'
);

SKIP: {
  skip("currently no raw HTML is allowed via the safe option", 1);
  is(
    $parser->render_html('<script>hijack()</script>'),
    "&lt;script&gt;hijack()&lt;/script&gt;\n",
    'Tagfilter extension'
  );
}

is(
  $parser->render_html('~~strikethrough~~'),
  "<p><del>strikethrough</del></p>\n",
  'Strikethrough extension'
);

my $table_markdown = <<'MARKDOWN';
| Col1 | Col2 |
| ---- |:----:|
| val1 | val2 |
MARKDOWN

my $table_html = <<'HTML';
<table>
<thead>
<tr>
<th>Col1</th>
<th align="center">Col2</th>
</tr>
</thead>
<tbody>
<tr>
<td>val1</td>
<td align="center">val2</td>
</tr>
</tbody>
</table>
HTML

is($parser->render_html($table_markdown), $table_html, 'Table extension');

# Test for bug 1802047: tables should work without blank line before them
my $table_no_blank = <<'MARKDOWN';
Some text before the table
| Field | Value | Source |
| ----- | ----- | ------ |
| Keywords | access | bug 1801513 |
MARKDOWN

my $rendered = $parser->render_html($table_no_blank);
like($rendered, qr{<table>}, 'Table renders without preceding blank line (bug 1802047)');

my $angle_link =  $parser->render_html("<https://searchfox.org/mozilla-central/rev/76fe4bb385348d3f45bbebcf69ba8c7283dfcec7/mobile/android/base/java/org/mozilla/gecko/toolbar/SecurityModeUtil.java#101>");
my $angle_link_dom = Mojo::DOM->new($angle_link);
my $ahref = $angle_link_dom->at('a[href]');
is($ahref->attr('href'), 'https://searchfox.org/mozilla-central/rev/76fe4bb385348d3f45bbebcf69ba8c7283dfcec7/mobile/android/base/java/org/mozilla/gecko/toolbar/SecurityModeUtil.java#101', 'angle links are parsed properly');

is($parser->render_html('<foo>'), "<p>&lt;foo&gt;</p>\n", "literal tags work");

# Bug 2060932: collapsible sections via <details>/<summary>.
is(
  $parser->render_html('<details><summary>Text to click</summary>'
    . 'Text hidden by default</details>'),
  '<details><summary>Text to click</summary>'
    . "<p>Text hidden by default</p></details>\n",
  'Disclosure tags on a single line'
);

my $details_block = <<'MARKDOWN';
<details>
<summary>Click **me**</summary>

Hidden content

</details>
MARKDOWN

is(
  $parser->render_html($details_block),
  "<details><summary>Click <strong>me</strong></summary>\n"
    . "<p>Hidden content</p>\n</details>\n",
  'Disclosure tags as their own blocks, with markdown in the summary'
);

is(
  $parser->render_html("<DETAILS><SUMMARY>Up</SUMMARY>hidden</DETAILS>"),
  "<details><summary>Up</summary><p>hidden</p></details>\n",
  'Disclosure tags are case insensitive'
);

is(
  $parser->render_html("```\n<details><summary>x</summary>y</details>\n```"),
  "<pre><code>&lt;details&gt;&lt;summary&gt;x&lt;/summary&gt;"
    . "y&lt;/details&gt;\n</code></pre>\n",
  'Disclosure tags in a code block stay literal'
);

is(
  $parser->render_html('Use `<details>` to fold.'),
  "<p>Use <code>&lt;details&gt;</code> to fold.</p>\n",
  'Disclosure tags in a code span stay literal'
);

like(
  $parser->render_html('<details open onclick="x">nope'),
  qr{&lt;details open onclick=&quot;x&quot;&gt;nope},
  'Only the bare disclosure tags are recognized'
);

is(
  $parser->render_html("\x{E000}\x{E002}nope\x{E003}\x{E001}"),
  "<p>nope</p>\n",
  'The internal disclosure markers cannot be forged in a comment'
);

# An unbalanced tag must not leak an unclosed element into the page.
like(
  $parser->render_html("<details>\n<summary>oops</summary>\n\nrest\n"),
  qr{</details>\z},
  'An unclosed disclosure section is closed for us'
);

done_testing;
