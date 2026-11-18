# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MozChangeField::Post::TypePriSevEditbugs;

use 5.10.1;
use Moo;

use Bugzilla::Constants;
use Bugzilla::Extension::MozChangeField::Pre::TypePriSevEditbugs;

my $RULE = 'Bugzilla::Extension::MozChangeField::Pre::TypePriSevEditbugs';

sub evaluate_change {
  my ($self, $args) = @_;
  my $changes = $args->{changes};

  # Backstop for the Pre rule: type needs editbugs; severity and priority need
  # editbugs or can_triage.
  foreach my $field (qw(bug_type bug_severity priority)) {
    if (exists $changes->{$field} && !$RULE->can_set_field($field, $args)) {
      ThrowUserError('mozchangefield_field_needs_editbugs', {field => $field});
    }
  }
}

1;
