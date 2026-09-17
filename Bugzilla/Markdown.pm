# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Markdown;
use 5.10.1;
use Moo;

use Encode;
use Mojo::DOM;
use Mojo::Util qw(trim);
use HTML::Escape qw(escape_html);
use List::MoreUtils qw(any);
use Bugzilla::Util qw(generate_random_password);

has 'markdown_parser' => (is => 'lazy');
has 'bugzilla_shorthand' => (
  is      => 'ro',
  default => sub {
    require Bugzilla::Template;
    \&Bugzilla::Template::quoteUrls;
  }
);

sub _build_markdown_parser {
  require Bugzilla::Markdown::GFM;
  require Bugzilla::Markdown::GFM::Parser;
  return Bugzilla::Markdown::GFM::Parser->new({
    hardbreaks    => 1,
    validate_utf8 => 1,
    safe          => 1,
    extensions    => [qw( autolink tagfilter table strikethrough )],
  });
}

my $MARKDOWN_OFF = quotemeta '#[markdown(off)]';

# The only raw HTML allowed in comments: GitHub-style collapsible sections.
# The raw tags are swapped for markers before the markdown is parsed, and
# those markers are turned into real elements afterwards. Marking them up
# front is what keeps a raw tag distinct from text that merely renders as one,
# such as an entity-encoded tag. Only these exact tags are recognized, and the
# bare `open` attribute on <details> is the only attribute they may carry, so
# no other markup can be smuggled in.

# Markdown wraps the tags in a paragraph. Closing and reopening it lets the
# HTML parser lift the block level disclosure elements out of the paragraph;
# the empty paragraphs left behind are dropped afterwards. Keyed by tag name,
# as a marker carries the name rather than the whole tag.
my %DISCLOSURE_HTML = (
  'details'      => '</p><details><p>',
  'details open' => '</p><details open><p>',
  '/details'     => '</p></details><p>',
  'summary'      => '</p><summary>',
  '/summary'     => '</summary><p>',
);

# <details open> starts a section already expanded. Only the bare attribute is
# recognized, so a marker never has to carry a quoted value, and the whitespace
# around it has to stay horizontal: a marker spanning a line break would be
# split by the hard break the parser puts there.
my $DISCLOSURE_OPEN_RE = qr{\h+open\h*}i;

my $DISCLOSURE_RE = qr{<details$DISCLOSURE_OPEN_RE?>|</details>|</?summary>}i;

# A marker wraps the tag name as the comment spelled it, so the marker is self
# describing: a tag that turns out to be a code literal is restored to the
# comment's own spelling, while one that becomes an element is named in
# canonical lower case.
my $DISCLOSURE_NAME_RE = qr{details$DISCLOSURE_OPEN_RE?|/details|/?summary}i;

# The private use characters a marker starts and ends with.
my $MARKER_START = chr 0xE000;
my $MARKER_END   = chr 0xE001;

# The markdown parser percent encodes those characters in a link destination,
# so a marker that ended up in one has to be recognized in that form too.
my $MARKER_START_RE = qr{(?:$MARKER_START|%EE%80%80)};
my $MARKER_END_RE   = qr{(?:$MARKER_END|%EE%80%81)};
my $MARKER_CHARS_RE = qr{[$MARKER_START$MARKER_END]};

# The markers for one comment: how to mark a tag, a regex capturing the name
# out of this comment's markers, and a regex for the marker characters that
# are not part of one.
#
# The characters on their own cannot mark a tag, because the markdown parser
# decodes character references: a comment containing &#xE000; hands back that
# character after the input has been scrubbed of it, forging a marker it never
# wrote as a tag. Wrapping the name in a token that is random per comment is
# what keeps the markers ours, as nothing in the comment can predict it.
sub _disclosure_markers {
  my $nonce = generate_random_password(16);

  return {
    mark => sub {
      # The tag without its angle brackets, which a marker cannot contain:
      # every remaining < in the comment is escaped before it is parsed.
      my $name = substr $_[0], 1, -1;

      # A name the lookup has no markup for is left as the comment wrote it,
      # rather than marked and expanded to nothing later on.
      return $_[0] unless defined _disclosure_key($name);
      return $MARKER_START . $nonce . $name . $nonce . $MARKER_END;
    },
    re => qr{
      $MARKER_START_RE \Q$nonce\E ($DISCLOSURE_NAME_RE) \Q$nonce\E
      $MARKER_END_RE
    }x,
    stray => qr/$MARKER_START(?!\Q$nonce\E)|(?<!\Q$nonce\E)$MARKER_END/,
  };
}

sub render_html {
  my ($self, $markdown, $bug, $comment, $user) = @_;
  my $parser = $self->markdown_parser;
  return escape_html($markdown) unless $parser;

  # This makes sure we never handle > foo text in the shortcuts code.
  local $Bugzilla::Template::COLOR_QUOTES = 0;

  if ($markdown =~ /^\s*$MARKDOWN_OFF\n/s) {
    my $text = $self->bugzilla_shorthand->(trim($markdown), $bug);
    my $dom = Mojo::DOM->new($text);
    $dom->find('*')->each(sub {
      my ($e) = @_;
      my $attr = $e->attr;
      foreach my $key (keys %$attr) {
        $attr->{$key} =~ s/\s+/ /gs;
      }
    });
    $text = $dom->to_string;
    my @p = split(/\n{2,}/, $text);
    my $html = join("\n", map { s/\n/<br>\n/gs; "<p>$_</p>\n" } @p );
    return $html;
  }

  # Replace < with \x{FFFD} (special unicode replacement character),
  # and remove \x{FFFD} later. The private use characters reserved for the
  # disclosure markers are dropped too, so they can't be forged in a comment.
  # Spelled out because tr does not interpolate: keep in step with
  # $MARKER_START and $MARKER_END.
  $markdown =~ tr/\x{FFFD}\x{E000}\x{E001}//d;

  # Mark the raw disclosure tags before the markdown is parsed, so that only
  # these occurrences can ever become elements again.
  my $disclosure;
  if ($markdown =~ $DISCLOSURE_RE) {
    $disclosure = _disclosure_markers();
    $markdown =~ s/($DISCLOSURE_RE)/$disclosure->{mark}->($1)/ge;
  }

  $markdown =~ s{<(?!https?://)}{\x{FFFD}}gs;

  my @valid_text_parent_tags = ('h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'li', 'td');
  my @bad_tags               = qw( img );
  my $bugzilla_shorthand     = $self->bugzilla_shorthand;
  my $html                   = decode('UTF-8', $parser->render_html($markdown));

  $html =~ s/\x{FFFD}/&lt;/g;

  # A character reference decodes to the character it names, so the comment
  # can still hand back one of the characters the markers are built from: the
  # scrub above only cleared the ones it wrote as characters. Drop anything
  # left in that range which is not a marker of ours.
  my $stray_marker_re = $disclosure ? $disclosure->{stray} : $MARKER_CHARS_RE;
  $html =~ s/$stray_marker_re//g;

  my $dom = Mojo::DOM->new($html);
  $dom->find(join(', ', @bad_tags))->map('remove');

  $dom->find("a[href]")->grep(\&_is_external_link)
      ->map(attr => {target => '_blank', rel => 'nofollow noreferrer'});
  $dom->find(join ', ', @valid_text_parent_tags)->map(sub {
    my $node = shift;
    $node->descendant_nodes->map(sub {
      my $child = shift;
      if ( $child->type eq 'text'
        && $child->children->size == 0
        && any { $child->parent->tag eq $_ } @valid_text_parent_tags)
      {
        my $text = $child->content;
        $child->replace(Mojo::DOM->new($bugzilla_shorthand->($text, $bug)));
      }
      return $child;
    });
    return $node;
  });
  return $dom->to_string unless $disclosure;
  return _expand_disclosure_tags($dom, $disclosure);
}

# Turn the markers left in place of the raw <details>/<summary> tags into real
# elements. A marker that ended up somewhere it cannot be expanded is restored
# as literal text: inside a code block, so the syntax can still be documented
# in a comment, or inside an attribute value, where only text belongs.
sub _expand_disclosure_tags {
  my ($dom, $disclosure) = @_;
  my $marker_re = $disclosure->{re};

  my $found = 0;
  $dom->descendant_nodes->each(sub {
    my ($node) = @_;

    if ($node->type eq 'tag') {
      my $attr = $node->attr;
      foreach my $key (keys %$attr) {
        next unless defined $attr->{$key};
        $attr->{$key} =~ s/$marker_re/<$1>/g;
      }
      return;
    }

    my $text = $node->content;
    return unless $text =~ $marker_re;
    if ($node->type eq 'text' && !$node->ancestors('pre, code')->size) {
      $found = 1;
      return;
    }
    $text =~ s/$marker_re/<$1>/g;
    $node->content($text);
  });

  my $html = $dom->to_string;
  return $html unless $found;

  $html =~ s/$marker_re/_disclosure_html($1)/ge;

  # Drop the line breaks and empty paragraphs the rewrite leaves behind.
  $html =~ s{\s*<br\s*/?>\s*(?=</p>)}{}g;
  $html =~ s{(?<=<p>)\s*<br\s*/?>\s*}{}g;

  my $expanded = Mojo::DOM->new($html);
  $expanded->find('p')
    ->grep(sub { !$_->children->size && $_->all_text !~ /\S/ })->map('remove');

  return $expanded->to_string;
}

# The %DISCLOSURE_HTML key a tag name belongs to, or nothing when it has no
# markup. A marker carries the tag name as the comment spelled it, so the case
# and the whitespace an `open` attribute was written with are normalized here.
#
# The name is checked against the keys rather than assumed to be one of them,
# because a case insensitive match is not the same thing as lc: Perl folds
# Unicode, so <detailſ> (U+017F) matches the tags while lc leaves that
# spelling alone.
sub _disclosure_key {
  my ($name) = @_;

  $name = lc $name;
  $name =~ s/$DISCLOSURE_OPEN_RE\z/ open/;
  return exists $DISCLOSURE_HTML{$name} ? $name : undef;
}

# The markup a marker expands to. The name was checked when the marker was
# made, so the key is always there.
sub _disclosure_html {
  my ($name) = @_;

  return $DISCLOSURE_HTML{_disclosure_key($name)};
}

sub _is_external_link {
  # the urlbase, without the trailing /
  state $urlbase = substr(Bugzilla->localconfig->urlbase, 0, -1);

  return index($_->attr('href'), $urlbase) != 0;
}


1;
