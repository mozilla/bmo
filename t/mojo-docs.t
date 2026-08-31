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
