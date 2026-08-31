# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Controller::Docs;

use 5.10.1;
use Mojo::Base 'Mojolicious::Controller';

use Bugzilla::Constants;
use Cwd qw(realpath);
use Encode qw(decode);
use File::Basename qw(basename);
use Mojo::DOM;
use Mojo::File ();

# The Markdown documentation lives in docs/en/md and its images in
# docs/en/images, so the /docs/en URL space mirrors docs/en on disk. That
# way the relative links inside the converted files (../using/index.md,
# ../../images/foo.png) resolve in the browser without any rewriting.
sub _docs_root { realpath(bz_locations()->{libpath} . '/docs/en') }

use constant IMAGE_TYPES => {
  gif  => 'image/gif',
  jpeg => 'image/jpeg',
  jpg  => 'image/jpeg',
  png  => 'image/png',
  svg  => 'image/svg+xml',
};

use constant ALERT_TITLES => {
  caution   => 'Caution',
  important => 'Important',
  note      => 'Note',
  tip       => 'Tip',
  warning   => 'Warning',
};

sub setup_routes {
  my ($class, $r) = @_;
  $r->get('/docs')->to('Docs#index')->name('docs_index');
  $r->get('/docs/en')->to('Docs#index');
  $r->get('/docs/en/*docs_path')->to('Docs#show')->name('docs_show');
}

sub index {    ## no critic (ProhibitBuiltinHomonyms)
  my ($self) = @_;
  return $self->redirect_to($self->url_for('docs_show', docs_path => 'md/index.md'));
}

sub show {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO);
  $self->bugzilla->login || return undef;

  my $path = $self->stash('docs_path') // '';
  $path =~ s{/+$}{};
  return $self->index if $path eq '';

  # Be careful not to allow directory traversal.
  if ($path =~ /\.\./ || $path !~ m{^[\w\-./]+$}) {
    return $self->_not_found($path);
  }

  my $root = _docs_root();
  my $file = realpath("$root/$path");
  unless (defined $file && CORE::index($file, "$root/") == 0 && (-f $file || -d $file)) {
    # The docs were once built to Sphinx HTML and served externally
    # (docs_urlbase), so old links and bookmarks use .html paths; send
    # those to the Markdown page with the same name.
    if ($path =~ m{^md/.+\.html$}) {
      (my $md_path = $path) =~ s/\.html$/.md/;
      my $md_file = realpath("$root/$md_path");
      if (defined $md_file && CORE::index($md_file, "$root/") == 0 && -f $md_file) {
        return $self->redirect_to(
          $self->url_for('docs_show', docs_path => $md_path));
      }
    }
    return $self->_not_found($path);
  }

  # Directory URLs (e.g. /docs/en/md, /docs/en/md/using) go to the
  # section's index page.
  if (-d $file) {
    return $self->_not_found($path) unless -f "$file/index.md";
    return $self->redirect_to(
      $self->url_for('docs_show', docs_path => "$path/index.md"));
  }

  if ($path =~ m{^md/.+\.md$}) {
    return $self->_render_markdown($file, $path);
  }

  if ($path =~ m{^images/.+\.(\w+)$} && IMAGE_TYPES->{lc $1}) {
    $self->res->headers->content_type(IMAGE_TYPES->{lc $1});
    return $self->reply->file($file);
  }

  return $self->_not_found($path);
}

sub _not_found {
  my ($self, $path) = @_;
  return $self->user_error('docs_page_not_found', {path => $path},
    {status => 404, skip_exception_page => 1});
}

sub _render_markdown {
  my ($self, $file, $path) = @_;

  require Bugzilla::Markdown::GFM;
  require Bugzilla::Markdown::GFM::Parser;

  my $markdown = Mojo::File->new($file)->slurp;

  # The documentation is trusted content shipped in the repository, so raw
  # HTML (the API reference tables, the <a id> anchors kept for deep links)
  # is allowed through; tagfilter still neutralizes script-capable tags.
  my $parser = Bugzilla::Markdown::GFM::Parser->new({
    unsafe        => 1,
    validate_utf8 => 1,
    extensions    => [qw( autolink tagfilter table strikethrough )],
  });

  my $dom = Mojo::DOM->new(decode('UTF-8', $parser->render_html($markdown)));
  _add_heading_ids($dom);
  _convert_alerts($dom);

  my $h1 = $dom->at('h1');
  my $title = $h1 ? $h1->all_text : basename($file, '.md');

  $self->stash(
    doc_html  => $dom->to_string,
    doc_title => $title,
    doc_path  => $path,
  );
  return $self->render(template => 'pages/doc_viewer', handler => 'bugzilla',
    format => 'html');
}

# cmark-gfm does not add ids to headings; GitHub does that in a separate
# pass. The docs link to GitHub-style heading slugs (lowercase; keep
# alphanumerics, "_" and "-"; spaces become "-"; everything else is
# dropped; duplicates get -1, -2, ...), so reproduce that algorithm or
# in-page anchors would dangle.
sub _add_heading_ids {
  my ($dom) = @_;
  my %seen;
  $dom->find('h1, h2, h3, h4, h5, h6')->each(sub {
    my ($h) = @_;
    return if defined $h->attr('id');
    my $slug = lc $h->all_text;
    $slug =~ s/^\s+|\s+$//g;
    $slug =~ s/[^\w\- \t]//g;
    $slug =~ s/[ \t]/-/g;
    my $count = $seen{$slug}++;
    $slug .= "-$count" if $count;
    $h->attr(id => $slug);
  });
}

# GitHub renders "> [!NOTE]" blockquotes as styled callouts; cmark-gfm
# leaves the marker as literal text, so turn those blockquotes into styled
# alert boxes here.
sub _convert_alerts {
  my ($dom) = @_;
  $dom->find('blockquote')->each(sub {
    my ($bq) = @_;
    my $p = $bq->at('p') or return;
    my $first = $p->child_nodes->first;
    return unless $first && $first->type eq 'text';
    my $text = $first->content;
    return unless $text =~ s/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*//;
    my $kind = lc $1;
    $first->content($text);
    $p->remove unless $p->all_text =~ /\S/ || $p->children->size;
    $bq->attr(class => "docs-alert docs-alert-$kind");
    $bq->prepend_content(
      qq{<p class="docs-alert-title">${\ ALERT_TITLES->{$kind}}</p>});
  });
}

1;
