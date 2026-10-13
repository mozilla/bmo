#!/usr/bin/env perl
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

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test2::V0;

sub split_flagtypes {
  my ($removed, $added) = @_;
  my $changes = {'flagtypes.name' => [$removed, $added]};
  my @result = Bugzilla::Extension::Push::_split_flagtypes($changes);
  ok(!exists $changes->{'flagtypes.name'}, 'flagtypes.name is removed');
  return \@result;
}

sub morph_flag_updates {
  my ($old_flags, $new_flags) = @_;
  my $args = {old_flags => $old_flags, new_flags => $new_flags};
  Bugzilla::Extension::Push::_morph_flag_updates($args);
  return $args->{changes};
}

is(
  split_flagtypes('', 'needinfo?(a@example.com)'),
  [['flag.needinfo', '', '? (a@example.com)']],
  'single needinfo request'
);

is(
  split_flagtypes('', 'needinfo?(a@example.com), needinfo?(b@example.com)'),
  [
    ['flag.needinfo', '', '? (a@example.com)'],
    ['flag.needinfo', '', '? (b@example.com)'],
  ],
  'needinfo requested from two users gives one change per requestee'
);

is(
  split_flagtypes('needinfo?(a@example.com), needinfo?(b@example.com)', ''),
  [
    ['flag.needinfo', '? (a@example.com)', ''],
    ['flag.needinfo', '? (b@example.com)', ''],
  ],
  'needinfo cleared for two users gives one change per requestee'
);

is(
  split_flagtypes('review?(a@example.com)', 'review+, needinfo?(b@example.com)'),
  [
    ['flag.needinfo', '',                 '? (b@example.com)'],
    ['flag.review',   '? (a@example.com)', '+'],
  ],
  'a single flag changing state is still one change'
);

is(
  morph_flag_updates(
    ['x:review?(a@example.com)'],
    ['x:review?(a@example.com)', 'y:review?(b@example.com)',
      'y:review?(c@example.com)']
  ),
  {'flagtypes.name' => ['', 'review?(b@example.com), review?(c@example.com)']},
  'attachment review requested from two more users keeps every added flag'
);

is(
  morph_flag_updates(['x:review?(a@example.com)'], ['y:review?(a@example.com)']),
  {}, 'a flag re-set by a different user is not a change'
);

is(
  split_flagtypes(
    'needinfo?(a@example.com), needinfo?(b@example.com)',
    'needinfo+, needinfo?(d@example.com)'
  ),
  [
    ['flag.needinfo', '? (a@example.com)', ''],
    ['flag.needinfo', '? (b@example.com)', ''],
    ['flag.needinfo', '',                  '+'],
    ['flag.needinfo', '',                  '? (d@example.com)'],
  ],
  'several changes to one flag type are not paired'
);

done_testing;
