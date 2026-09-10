#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test/');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;

use Test2::V0;
use Test::Mojo;

# Rendering the docs requires libcmark-gfm.
eval { require Bugzilla::Markdown::GFM; 1 }
  or plan skip_all => 'libcmark-gfm is not available';

my $t = Test::Mojo->new('Bugzilla::App');

# /docs and /docs/en redirect to the documentation home page.
$t->get_ok('/docs')->status_is(302)
  ->header_like(Location => qr{/docs/en/md/index\.md$});
$t->get_ok('/docs/en')->status_is(302)
  ->header_like(Location => qr{/docs/en/md/index\.md$});

# The home page renders inside the normal Bugzilla chrome.
$t->get_ok('/docs/en/md/index.md')->status_is(200)
  ->element_exists('#header', 'Bugzilla page header is present');
$t->element_exists('main#bugzilla-body .docs-content',
  'docs render inside the standard page body')
  ->text_like('.docs-content h1' => qr/Documentation/);

# The home page table of contents renders without list bullets
# (docs-index class); other pages keep normal lists.
$t->get_ok('/docs/en/md/index.md')
  ->element_exists('.docs-content.docs-index', 'home page has docs-index class');

# Sub-pages render and headings get GitHub-style anchor ids.
$t->get_ok('/docs/en/md/using/index.md')->status_is(200)
  ->element_exists('.docs-content h1[id]', 'headings carry generated ids');
$t->element_exists_not('.docs-content.docs-index',
  'sub-pages do not get the docs-index class');

# GFM alert blockquotes become styled callouts.
$t->get_ok('/docs/en/md/integrating/templates.md')->status_is(200)
  ->element_exists('.docs-alert.docs-alert-warning');
$t->text_is('.docs-alert-warning .docs-alert-title' => 'Warning');

# Directory URLs redirect to the section index.
$t->get_ok('/docs/en/md/using')->status_is(302)
  ->header_like(Location => qr{/docs/en/md/using/index\.md$});

# Legacy Sphinx-style .html links (old docs_urlbase bookmarks) redirect to
# the Markdown page with the same name.
$t->get_ok('/docs/en/md/using/finding.html')->status_is(302)
  ->header_like(Location => qr{/docs/en/md/using/finding\.md$});
$t->get_ok('/docs/en/md/no-such-page.html')->status_is(404);

# Images shipped with the docs are served.
SKIP: {
  skip 'no sample image in docs/en/images', 1
    unless -f 'docs/en/images/bzLifecycle.png';
  $t->get_ok('/docs/en/images/bzLifecycle.png')->status_is(200)
    ->header_is('Content-Type' => 'image/png');
}

# The search form is on every documentation page.
$t->get_ok('/docs/en/md/index.md')
  ->element_exists('form.docs-search input[name="q"]',
  'the docs home page has a search field')
  ->element_exists('form.docs-search button[type="submit"]');
$t->get_ok('/docs/en/md/using/finding.md')
  ->element_exists('form.docs-search input[name="q"]',
  'sub-pages have a search field too');

# An empty query just prompts for keywords.
$t->get_ok('/docs/en/search')->status_is(200);
$t->element_exists_not('.docs-search-result', 'no results without a query')
  ->text_like('.docs-search-results p' => qr/Enter one or more keywords/);

# Searching finds pages, links to the matching section and highlights the
# keywords in the snippet.
$t->get_ok('/docs/en/search?q=quicksearch')->status_is(200)
  ->element_exists('.docs-search-result', 'quicksearch matches something');
$t->element_exists('.docs-search-result a[href*="using/finding.md"]',
  'the finding page is among the results')
  ->element_exists('.docs-search-match a.docs-search-heading[href*="#"]',
  'matches link to a heading anchor')
  ->text_like('.docs-search-snippet mark' => qr/quicksearch/i);

# The anchor a result links to really exists on the target page.
my $results_dom = $t->tx->res->dom;
my $heading_link
  = $results_dom->at('a.docs-search-heading[href*="using/finding.md#"]');
ok($heading_link, 'a result links into a section of the finding page');
if ($heading_link) {
  (my $anchor = $heading_link->attr('href')) =~ s/^.*#//;
  $t->get_ok('/docs/en/md/using/finding.md')
    ->element_exists(qq{.docs-content [id="$anchor"]},
    "heading anchor #$anchor exists on the page it links to");
}

# All keywords have to match, and unmatched queries say so.
$t->get_ok('/docs/en/search?q=quicksearch+zzzznotaword')->status_is(200);
$t->element_exists_not('.docs-search-result',
  'every keyword has to appear on the page')
  ->text_like('.docs-search-results p' => qr/No documentation pages match/);

# Directory traversal and non-doc files are rejected.
$t->get_ok('/docs/en/md/../../../Bugzilla.pm')->status_is(404);
$t->get_ok('/docs/en/localconfig')->status_is(404);
$t->get_ok('/docs/en/md/no-such-page.md')->status_is(404);

# The docs_urlbase parameter is gone, but the template variable now points
# at the in-app viewer: the header help menu should link to it.
ok(!exists Bugzilla->params->{docs_urlbase},
  'docs_urlbase parameter no longer exists');
$t->get_ok('/docs/en/md/index.md')
  ->element_exists('#header a[href="/docs/en/md/"]',
  'header Documentation menu links to the in-app docs');

done_testing;
