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
# The raw tags are swapped for private use characters before the markdown is
# parsed, and those markers are turned into real elements afterwards. Marking
# them up front is what keeps a raw tag distinct from text that merely renders
# as one, such as an entity-encoded tag. Only these exact tags are recognized
# and they never carry attributes, so no other markup can be smuggled in.
my %DISCLOSURE_MARKER = (
  '<details>'  => chr 0xE000,
  '</details>' => chr 0xE001,
  '<summary>'  => chr 0xE002,
  '</summary>' => chr 0xE003,
);

# Marker back to the tag it stands for, for markers that cannot be expanded.
my %DISCLOSURE_TAG = reverse %DISCLOSURE_MARKER;

# Markdown wraps the tags in a paragraph. Closing and reopening it lets the
# HTML parser lift the block level disclosure elements out of the paragraph;
# the empty paragraphs left behind are dropped afterwards.
my %DISCLOSURE_HTML = (
  $DISCLOSURE_MARKER{'<details>'}  => '</p><details><p>',
  $DISCLOSURE_MARKER{'</details>'} => '</p></details><p>',
  $DISCLOSURE_MARKER{'<summary>'}  => '</p><summary>',
  $DISCLOSURE_MARKER{'</summary>'} => '</summary><p>',
);

my $DISCLOSURE_RE        = qr{</?(?:details|summary)>}i;
my $DISCLOSURE_MARKER_RE = qr{[\x{E000}-\x{E003}]};

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
  $markdown =~ tr/\x{FFFD}\x{E000}-\x{E003}//d;

  # Mark the raw disclosure tags before the markdown is parsed, so that only
  # these occurrences can ever become elements again.
  my $has_disclosure
    = $markdown =~ s/($DISCLOSURE_RE)/$DISCLOSURE_MARKER{lc $1}/g;

  $markdown =~ s{<(?!https?://)}{\x{FFFD}}gs;

  my @valid_text_parent_tags = ('h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'li', 'td');
  my @bad_tags               = qw( img );
  my $bugzilla_shorthand     = $self->bugzilla_shorthand;
  my $html                   = decode('UTF-8', $parser->render_html($markdown));

  $html =~ s/\x{FFFD}/&lt;/g;
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
  return $has_disclosure ? _expand_disclosure_tags($dom) : $dom->to_string;
}

# Turn the markers left in place of the raw <details>/<summary> tags into real
# elements. A marker that ended up somewhere it cannot be expanded is restored
# as literal text: inside a code block, so the syntax can still be documented
# in a comment, or inside an attribute value, where only text belongs.
sub _expand_disclosure_tags {
  my ($dom) = @_;

  my $found = 0;
  $dom->descendant_nodes->each(sub {
    my ($node) = @_;

    if ($node->type eq 'tag') {
      my $attr = $node->attr;
      foreach my $key (keys %$attr) {
        next unless defined $attr->{$key};
        $attr->{$key} =~ s/($DISCLOSURE_MARKER_RE)/$DISCLOSURE_TAG{$1}/g;
      }
      return;
    }

    my $text = $node->content;
    return unless $text =~ $DISCLOSURE_MARKER_RE;
    if ($node->type eq 'text' && !$node->ancestors('pre, code')->size) {
      $found = 1;
      return;
    }
    $text =~ s/($DISCLOSURE_MARKER_RE)/$DISCLOSURE_TAG{$1}/g;
    $node->content($text);
  });

  my $html = $dom->to_string;
  return $html unless $found;

  $html =~ s/($DISCLOSURE_MARKER_RE)/$DISCLOSURE_HTML{$1}/g;

  # Drop the line breaks and empty paragraphs the rewrite leaves behind.
  $html =~ s{\s*<br\s*/?>\s*(?=</p>)}{}g;
  $html =~ s{(?<=<p>)\s*<br\s*/?>\s*}{}g;

  my $expanded = Mojo::DOM->new($html);
  $expanded->find('p')
    ->grep(sub { !$_->children->size && $_->all_text !~ /\S/ })->map('remove');

  return $expanded->to_string;
}

sub _is_external_link {
  # the urlbase, without the trailing /
  state $urlbase = substr(Bugzilla->localconfig->urlbase, 0, -1);

  return index($_->attr('href'), $urlbase) != 0;
}


1;
