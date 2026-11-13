#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;

use Test2::V0;

use Bugzilla;
BEGIN { Bugzilla->extensions }

my $parse = \&Bugzilla::Extension::Hackbot::Metadata::parse_front_matter;

my $url = 'https://hackbot.moz.tools/runs/abc-123';

sub block {
  my (%fields) = (run => 'abc-123', action => 'f00', agent => 'bug-fix', @_);
  my $lines = join('', map {
    defined $fields{$_} ? "  $_: $fields{$_}\n" : ''
  } qw(run action agent url extra));
  return "---\nhackbot:\n$lines---\n";
}

my ($metadata, $body) = $parse->(block(url => $url) . "\nThe failure is here.\n");
is(
  $metadata,
  {run => 'abc-123', action => 'f00', agent => 'bug-fix', url => $url},
  'fields are read'
);
is($body, "The failure is here.\n", 'block and blank line are removed');

($metadata, $body) = $parse->(block());
is($body, '', 'a block with no text after it');

($metadata, $body) = $parse->(substr(block(), 0, -1));
is($metadata->{run}, 'abc-123', 'stored text has its final newline trimmed');

($metadata) = $parse->(block(extra => 'value'));
ok(!exists $metadata->{extra}, 'unknown keys are skipped');

($metadata, $body) = $parse->(block() . "\nA\n\n---\n\nB");
is($body, "A\n\n---\n\nB", 'a later rule is part of the text');

($metadata, $body) = $parse->(block() . block() . 'text');
is($body, block() . 'text', 'only the first block counts');

($metadata) = $parse->(block(url => 'javascript:alert(1)'));
is($metadata->{run}, 'abc-123', 'a bad url does not reject the block');
ok(!exists $metadata->{url}, 'only https URLs are kept');

($metadata) = $parse->(block(url => 'https://a.test/"x y'));
ok(!exists $metadata->{url}, 'a URL with spaces is dropped');

for my $key (qw(run action agent)) {
  is([$parse->(block($key => undef))], [], "$key is required");
  is([$parse->(block($key => '<b>'))], [], "$key must be an identifier");
}

is([$parse->(undef)], [], 'undef text');
is([$parse->('')], [], 'empty text');
is([$parse->('Plain comment')], [], 'plain comment');
is([$parse->("---\n\nA comment starting with a rule")], [], 'leading rule');
is([$parse->("---\ntitle: x\n---\ntext")], [], 'other front matter');
is([$parse->('Text first' . block())], [], 'block not at the top');
is([$parse->("\n" . block())], [], 'block after a blank line');
is([$parse->("---\nhackbot:\n  run: x\n")], [], 'unterminated block');

done_testing;
