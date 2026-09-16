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

# A code literal is the comment's own text, so marking the tags must not
# normalize the spelling of the ones that turn out to be literals. Only the
# tags that become elements are named in canonical lower case.
is(
  $parser->render_html("```\n<DETAILS><SUMMARY>x</SUMMARY>y</DETAILS>\n```"),
  "<pre><code>&lt;DETAILS&gt;&lt;SUMMARY&gt;x&lt;/SUMMARY&gt;"
    . "y&lt;/DETAILS&gt;\n</code></pre>\n",
  'A literal disclosure tag keeps the spelling the comment used'
);

is(
  $parser->render_html('Use `<DeTaIlS>` to fold.'),
  "<p>Use <code>&lt;DeTaIlS&gt;</code> to fold.</p>\n",
  'A disclosure tag in a code span keeps the spelling the comment used'
);

is(
  $parser->render_html('<details open><summary>x</summary>y</details>'),
  "<details open><summary>x</summary><p>y</p></details>\n",
  'The open attribute starts a section expanded'
);

is(
  $parser->render_html('<DETAILS OPEN ><summary>x</summary>y</details>'),
  "<details open><summary>x</summary><p>y</p></details>\n",
  'The open attribute is case insensitive and tolerates whitespace'
);

is(
  $parser->render_html('Use `<DETAILS OPEN>` to fold.'),
  "<p>Use <code>&lt;DETAILS OPEN&gt;</code> to fold.</p>\n",
  'An open disclosure tag in a code span keeps the spelling the comment used'
);

is(
  $parser->render_html('<summary open>nope'),
  "<p>&lt;summary open&gt;nope</p>\n",
  'The open attribute is only recognized on <details>'
);

like(
  $parser->render_html('<details open onclick="x">nope'),
  qr{&lt;details open onclick=&quot;x&quot;&gt;nope},
  'The open attribute is the only attribute recognized'
);

# A marker must not span a line break, or the hard break the parser puts there
# would split it and spill its innards into the page.
like(
  $parser->render_html("<details\nopen>hidden?"),
  qr{\A<p>&lt;details<br>\nopen&gt;hidden\?</p>\n\z},
  'A disclosure tag split over two lines is not recognized'
);

# Only the raw tags in the comment are expanded; text that merely renders as a
# tag must not be able to close the section early and reveal hidden content.
is(
  $parser->render_html('<details><summary>x</summary>'
    . '&lt;/details&gt;hidden</details>'),
  '<details><summary>x</summary>'
    . "<p>&lt;/details&gt;hidden</p></details>\n",
  'Entity encoded disclosure tags are not expanded'
);

is(
  $parser->render_html('Use `<details>` for &lt;summary&gt;a&lt;/summary&gt;'),
  '<p>Use <code>&lt;details&gt;</code> for '
    . "&lt;summary&gt;a&lt;/summary&gt;</p>\n",
  'A raw tag in a code span does not expand entity encoded tags elsewhere'
);

# Spelled with chr() rather than \x escapes, which perlcritic flags.
my $marker_start = chr 0xE000;
my $marker_end   = chr 0xE001;

is(
  $parser->render_html(
    "${marker_start}details${marker_end}${marker_start}summary${marker_end}nope"
  ),
  "<p>detailssummarynope</p>\n",
  'The marker characters cannot be forged in a comment'
);

# A character reference is decoded by the markdown parser, after the comment
# has been scrubbed of the marker characters, so it must not be able to hand
# back a marker. Otherwise a comment with one real disclosure tag could close
# the section early and reveal the content hidden in it, or open a section of
# its own and hide what follows.
foreach my $reference ('&#xE001;', '&#57345;', '&#x0000E001;') {
  is(
    $parser->render_html(
      "<details><summary>x</summary>${reference}visible</details>"
    ),
    "<details><summary>x</summary><p>visible</p></details>\n",
    "A $reference character reference cannot forge a disclosure marker"
  );
}

is(
  $parser->render_html(
    '<details><summary>x</summary>y</details> &#xE000;hidden?'
  ),
  '<details><summary>x</summary><p>y</p></details>'
    . "<p> hidden?</p>\n",
  'A character reference cannot open a section of its own'
);

# The characters the markers are built from are never content, so a reference
# to one leaves nothing behind, whether or not the comment has a real tag.
is(
  $parser->render_html('a&#xE000;b&#xE001;c'),
  "<p>abc</p>\n",
  'References to the reserved characters are dropped'
);

# A marker is percent encoded when it lands in a link destination, where it
# has to be recognized too: otherwise the token meant to stay internal is
# served as part of the URL.
like(
  $parser->render_html('[a](http://x/<DETAILS>)'),
  qr{href="http://x/&lt;DETAILS&gt;"},
  'A marker in a link destination is restored, not served as the URL'
);

# Perl's case insensitive match folds Unicode, so a spelling like <detail\x{17f}>
# matches the disclosure tags while lc does not turn it into a tag name. Such a
# tag has no markup to expand to and must be left as the comment wrote it,
# rather than marked and then dropped, deleting the text.
my $long_s = chr 0x17F;

foreach my $tag ("<detail$long_s>", "<detail$long_s open>", "</detail$long_s>",
  "<$long_s" . 'ummary>', "</$long_s" . 'ummary>')
{
  my $name = substr $tag, 1, -1;
  is(
    $parser->render_html("${tag}text"),
    "<p>&lt;${name}&gt;text</p>\n",
    "A $tag Unicode case fold of a disclosure tag is kept literally"
  );
}

# An unbalanced tag must not leak an unclosed element into the page.
like(
  $parser->render_html("<details>\n<summary>oops</summary>\n\nrest\n"),
  qr{</details>\z},
  'An unclosed disclosure section is closed for us'
);

done_testing;
