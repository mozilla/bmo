# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Controller::Docs;

use 5.10.1;
use utf8;
use Mojo::Base 'Mojolicious::Controller';

use Bugzilla::Constants;
use Bugzilla::Util qw(trim);
use Cwd            qw(realpath);
use Encode         qw(decode);
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

# Tuning for the keyword search (Docs#search).
use constant SEARCH_MAX_SECTIONS => 3;     # matching sections shown per page
use constant SEARCH_SNIPPET_PAD  => 90;    # characters of context per snippet

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

  # Before the catch-all below so /docs/en/search wins.
  $r->get('/docs/en/search')->to('Docs#search')->name('docs_search');
  $r->get('/docs/en/*docs_path')->to('Docs#show')->name('docs_show');
}

sub index {    ## no critic (ProhibitBuiltinHomonyms)
  my ($self) = @_;
  return $self->redirect_to(
    $self->url_for('docs_show', docs_path => 'md/index.md'));
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
  unless (defined $file
    && CORE::index($file, "$root/") == 0
    && (-f $file || -d $file))
  {
    # The docs were once built to Sphinx HTML and served externally
    # (docs_urlbase), so old links and bookmarks use .html paths; send
    # those to the Markdown page with the same name.
    if ($path =~ m{^md/.+\.html$}) {
      (my $md_path = $path) =~ s/\.html$/.md/;
      my $md_file = realpath("$root/$md_path");
      if (defined $md_file && CORE::index($md_file, "$root/") == 0 && -f $md_file) {
        return $self->redirect_to($self->url_for('docs_show', docs_path => $md_path));
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

# Keyword search over the Markdown sources (the search form at the top of
# every documentation page posts here).
sub search {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO);
  $self->bugzilla->login || return undef;

  my $query   = trim($self->param('q') // '');
  my @terms   = _parse_query($query);
  my @results = @terms ? _search_docs(\@terms) : ();

  $self->stash(doc_query => $query, doc_results => \@results);
  return $self->render(
    template => 'pages/doc_search',
    handler  => 'bugzilla',
    format   => 'html'
  );
}

sub _not_found {
  my ($self, $path) = @_;
  return $self->user_error(
    'docs_page_not_found',
    {path   => $path},
    {status => 404, skip_exception_page => 1}
  );
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

  my $h1    = $dom->at('h1');
  my $title = $h1 ? $h1->all_text : basename($file, '.md');

  $self->stash(
    doc_html  => $dom->to_string,
    doc_title => $title,
    doc_path  => $path,
  );
  return $self->render(
    template => 'pages/doc_viewer',
    handler  => 'bugzilla',
    format   => 'html'
  );
}

# cmark-gfm does not add ids to headings; GitHub does that in a separate
# pass. The docs link to GitHub-style heading slugs, so reproduce that
# algorithm or in-page anchors would dangle.
sub _add_heading_ids {
  my ($dom) = @_;
  my %seen;
  $dom->find('h1, h2, h3, h4, h5, h6')->each(sub {
    my ($h) = @_;
    return if defined $h->attr('id');
    $h->attr(id => _heading_slug($h->all_text, \%seen));
  });
}

# Lowercase; keep alphanumerics, "_" and "-"; spaces become "-"; everything
# else is dropped; duplicates get -1, -2, ... The search index slugs the
# headings the same way so its links land on the right anchor.
sub _heading_slug {
  my ($text, $seen) = @_;
  my $slug = lc $text;
  $slug =~ s/^\s+|\s+$//g;
  $slug =~ s/[^\w\- \t]//g;
  $slug =~ s/[ \t]/-/g;
  my $count = $seen->{$slug}++;
  $slug .= "-$count" if $count;
  return $slug;
}

# GitHub renders "> [!NOTE]" blockquotes as styled callouts; cmark-gfm
# leaves the marker as literal text, so turn those blockquotes into styled
# alert boxes here.
sub _convert_alerts {
  my ($dom) = @_;
  $dom->find('blockquote')->each(sub {
    my ($bq)  = @_;
    my $p     = $bq->at('p') or return;
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

# Split the query into lowercased keywords. "Quoted phrases" are kept
# together; everything else is whitespace separated.
sub _parse_query {
  my ($query) = @_;
  my %seen;
  return
    grep { $_ ne '' && !$seen{$_}++ }
    map { trim(lc $_) } grep {defined} $query =~ /"([^"]*)"|(\S+)/g;
}

# Every page containing all of the keywords, best match first.
sub _search_docs {
  my ($terms) = @_;

  # Keywords match at the start of a word, so "key" finds "keys" and
  # "keyword" but not "monkey" or "sort_key".
  my @matchers = map {qr/(?<!\w)\Q$_\E/i} @$terms;

  # Longest keyword first so that overlapping keywords are highlighted as
  # the widest match rather than as a fragment of one. The lengths and the
  # scores below are negated so that the comparisons can be written with
  # $a before $b (perlcritic).
  my $alternation = join '|',
    map {quotemeta} sort { -length($a) <=> -length($b) } @$terms;
  my $highlight = qr/((?<!\w)(?:$alternation))/i;

  my @results
    = grep {$_} map { _match_doc($_, \@matchers, $highlight) } @{_docs_index()};

  @results = sort {
    -$a->{score} <=> -$b->{score} || lc($a->{title}) cmp lc($b->{title})
  } @results;
  return @results;
}

# Score one page against the keywords, returning undef unless all of them
# appear somewhere in it. A hit in the page title counts for more than a
# hit in the text.
sub _match_doc {
  my ($doc, $matchers, $highlight) = @_;

  # Every keyword has to appear somewhere on the page.
  foreach my $matcher (@$matchers) {
    return undef if $doc->{all_text_lc} !~ /$matcher/;
  }

  my $score = 10 * grep { $doc->{title_lc} =~ /$_/ } @$matchers;

  my @matched;
  foreach my $section (@{$doc->{sections}}) {
    my $hits = 0;
    foreach my $matcher (@$matchers) {
      $hits += (() = $section->{search_lc} =~ /$matcher/g);
    }
    next unless $hits;
    $score += $hits;
    push @matched, {%$section, hits => $hits};
  }

  # The sections with the most hits are the most useful to link to.
  @matched = sort { -$a->{hits} <=> -$b->{hits} } @matched;
  splice @matched, SEARCH_MAX_SECTIONS if @matched > SEARCH_MAX_SECTIONS;

  # A page can match on its title alone; show the top of it in that case.
  @matched = ($doc->{sections}[0]) if !@matched && @{$doc->{sections}};

  return {
    path    => $doc->{path},
    title   => $doc->{title},
    score   => $score,
    matches => [
      map { {
        heading => $_->{heading},
        anchor  => $_->{anchor},
        snippet => _snippet($_->{text}, $highlight),
      } } @matched
    ],
  };
}

# An excerpt of the section centred on its first keyword, returned as a
# list of {text, match} segments so the template can highlight the keywords
# without the controller having to build HTML.
sub _snippet {
  my ($text, $highlight) = @_;

  $text =~ s/\s+/ /g;
  $text = trim($text);
  return [] if $text eq '';

  my $first   = $text =~ /$highlight/       ? $-[0]                       : 0;
  my $start   = $first > SEARCH_SNIPPET_PAD ? $first - SEARCH_SNIPPET_PAD : 0;
  my $excerpt = substr($text, $start, 3 * SEARCH_SNIPPET_PAD);

  # The fixed-width window cuts words in half at both ends; the keyword is
  # far enough inside it that trimming those cannot reach it.
  $excerpt =~ s/^\S+ (?=\S)/…/ if $start > 0;
  $excerpt =~ s/ \S+$/…/       if $start + length($excerpt) < length($text);

  # The keywords are captured, so splitting on them puts the matches at the
  # odd indexes of the resulting list.
  my @pieces = split $highlight, $excerpt;
  return [map { {text => $pieces[$_], match => $_ % 2} }
    grep { defined $pieces[$_] && $pieces[$_] ne '' } 0 .. $#pieces];
}

# The Markdown files are static, so they are only parsed once per process.
# Restart the server after editing the docs; morbo only watches the code.
sub _docs_index {
  my $index = Bugzilla->process_cache->{docs_search_index};
  return $index if $index;

  my $root  = _docs_root();
  my @files = sort map { $_->to_string }
    @{Mojo::File->new("$root/md")->list_tree->grep(qr/\.md$/)};
  return Bugzilla->process_cache->{docs_search_index}
    = [map { _index_file($_, $root) } @files];
}

# Split one Markdown file into its sections, one per heading, so that a hit
# can link straight to the relevant part of the page. The headings are
# slugged exactly as _add_heading_ids slugs the rendered ones.
sub _index_file {
  my ($file, $root) = @_;

  my $path = $file;
  $path =~ s{^\Q$root\E/md/}{};

  my $content = decode('UTF-8', Mojo::File->new($file)->slurp);
  my $section = {heading => '', anchor => '', text => ''};
  my (@sections, %seen, $in_code);

  foreach my $line (split /\n/, $content) {

    # Fenced code blocks hold shell examples full of "# comment" lines,
    # which must not be mistaken for headings.
    if ($line =~ /^\s{0,3}(?:```|~~~)/) {
      $in_code = !$in_code;
      next;
    }
    if (!$in_code && $line =~ /^\#{1,6}\s+(.+?)\s*\#*\s*$/) {
      my $heading = _plain_text($1);
      push @sections, $section
        if $section->{heading} ne '' || $section->{text} =~ /\S/;
      $section = {
        heading => $heading,
        anchor  => _heading_slug($heading, \%seen),
        text    => '',
      };
      next;
    }
    $section->{text} .= "$line\n";
  }
  push @sections, $section
    if $section->{heading} ne '' || $section->{text} =~ /\S/;

  # The first heading in the file is its title.
  my $title
    = @sections && $sections[0]{heading} ne ''
    ? $sections[0]{heading}
    : basename($file, '.md');

  foreach my $s (@sections) {
    $s->{text} = _plain_text($s->{text});
    $s->{heading} ||= $title;

    # A heading is searched along with the text it introduces.
    $s->{search_lc} = lc "$s->{heading} $s->{text}";
  }

  return {
    path        => $path,
    title       => $title,
    title_lc    => lc $title,
    all_text_lc => join(' ', lc $title, map { $_->{search_lc} } @sections),
    sections    => \@sections,
  };
}

# Strip the Markdown syntax that would otherwise show up in the snippets or
# get in the way of matching. This does not have to be perfect: the result
# is only used for searching and for the excerpts on the results page.
sub _plain_text {
  my ($text) = @_;
  $text =~ s/!\[([^\]]*)\]\([^)]*\)/$1/g;    # images
  $text =~ s/\[([^\]]*)\]\([^)]*\)/$1/g;     # inline links
  $text =~ s/<[^>]+>//g;                     # raw HTML tags and anchors
  $text =~ s/`+//g;                          # code spans
  $text =~ s/\*\*|__//g;                     # bold
  $text =~ s/^\s{0,3}[-*+]\s+/ /gm;          # list bullets
  $text =~ s/^\s{0,3}>\s?/ /gm;              # blockquote markers
  return $text;
}

1;
