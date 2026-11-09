# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot::Metadata;

use 5.10.1;
use strict;
use warnings;

use base qw(Exporter);

our @EXPORT_OK = qw(parse_front_matter);

# The block hackbot-api puts at the top of a comment:
#
#   ---
#   hackbot:
#     run: 550e8400-e29b-41d4-a716-446655440000
#     action: 3f2a9c1e7b4d4f0a8e6c2d1b5a7f9e30
#     agent: bug-fix
#     url: https://hackbot.moz.tools/runs/550e8400-e29b-41d4-a716-446655440000
#   ---
#
# It is only ever generated, so this reads that one shape rather than YAML in
# general. Anything else is an ordinary comment that happens to start with a
# rule, and unknown keys are skipped so that fields can be added. The /a flag
# keeps the character classes to ASCII.
my $FRONT_MATTER
  = qr/\A---\nhackbot:\n((?:  [[:lower:]_]+: [^\n]*\n)+)---(?:\n+|\z)(.*)\z/as;
my $FIELD      = qr/^  ([[:lower:]_]+): ([^\n]*?)\s*$/am;
my $IDENTIFIER = qr/\A[[:alnum:]._-]+\z/a;

# Returns the metadata hash and the comment text without the block, or an empty
# list when the text doesn't start with a valid block. The url key is left out
# unless it is an https URL, because it ends up in a link's href.
sub parse_front_matter {
  my ($text) = @_;

  my ($block, $body) = ($text // '') =~ $FRONT_MATTER or return;

  my %fields = $block =~ /$FIELD/g;

  my %metadata;
  foreach my $key (qw(run action agent)) {
    return unless ($fields{$key} // '') =~ $IDENTIFIER;
    $metadata{$key} = $fields{$key};
  }
  $metadata{url} = $fields{url} if ($fields{url} // '') =~ m{\Ahttps://\S+\z};

  return (\%metadata, $body);
}

1;
