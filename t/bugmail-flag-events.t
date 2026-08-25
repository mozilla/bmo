# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#############################
#Bug 1883428: BugMail flag events
#############################

# Covers Bugzilla::BugMail::_flag_event_visible_to(), the private-attachment
# gate shared by recipient selection, per-recipient flag_events filtering,
# and the dequeue-time TOCTOU re-check. This is the one piece of the
# recipient-selection logic (bug 1883428 review) that's pure Perl and
# doesn't need a live DB to exercise; the flag_activity prev-status query
# and the flag-type cc_list DB lookups still need a real Bugzilla instance
# and are covered by the manual test plan in that bug instead.

package main;

use 5.10.1;
use strict;
use warnings;

use lib qw(. lib local/lib/perl5 t);
use Support::Files;
use Test::More tests => 6;

BEGIN { use_ok('Bugzilla::BugMail'); }

package Mock::Attachment;

sub new {
  my ($class, $private) = @_;
  return bless {isprivate => $private}, $class;
}
sub isprivate { return $_[0]->{isprivate}; }

package Mock::User;

sub new {
  my ($class, $insider) = @_;
  return bless {is_insider => $insider}, $class;
}
sub is_insider { return $_[0]->{is_insider}; }

package main;

## no critic (Variables::ProtectPrivateVars)
my $visible = \&Bugzilla::BugMail::_flag_event_visible_to;

ok(
  $visible->({attachment => undef}, Mock::User->new(0)),
  'no attachment on the event is always visible'
);

ok($visible->({attachment => Mock::Attachment->new(0)}, Mock::User->new(0)),
  'non-private attachment is visible to a non-insider');

ok($visible->({attachment => Mock::Attachment->new(1)}, Mock::User->new(1)),
  'private attachment is visible to an insider');

ok(!$visible->({attachment => Mock::Attachment->new(1)}, Mock::User->new(0)),
  'private attachment is hidden from a non-insider');

ok(
  !$visible->({attachment => Mock::Attachment->new(1)}, undef),
  'private attachment is hidden when there is no user to check'
);
