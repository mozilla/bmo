# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MozChangeField::Pre::TypePriSevEditbugs;

use 5.10.1;
use Moo;

use Bugzilla;
use Bugzilla::Constants;

# Fields reset to their default when a user may not set them on a new bug.
# bug_type is deliberately absent: it is required on bug entry and
# check_can_change_field lets anyone set it when filing.
my %CREATE_DEFAULT_PARAM
  = (bug_severity => 'defaultseverity', priority => 'defaultpriority');

# Who may set each field. Triagers need severity and priority to triage
# (BMO requires an S* severity on triaged defects), so can_triage is enough
# for those; bug_type stays editbugs only.
my %ALLOWED_BY = (
  bug_type     => ['editbugs'],
  bug_severity => ['editbugs', 'can_triage'],
  priority     => ['editbugs', 'can_triage'],
);

# True unless $field is restricted and the user holds none of the permissions
# that allow it. $perms is the hash built by _populate_permissions. Also used
# by Post::TypePriSevEditbugs so update and create share one rule.
sub can_set_field {
  my ($class, $field, $perms) = @_;
  my $allowed_by = $ALLOWED_BY{$field} or return 1;
  return scalar grep { $perms->{$_} } @$allowed_by;
}

sub evaluate_change {
  my ($self, $args) = @_;
  my $field = $args->{'field'};

  return undef if $self->can_set_field($field, $args);

  my $who = join(' or ', map {"\"$_\""} @{$ALLOWED_BY{$field}});
  return {
    result => PRIVILEGES_REQUIRED_EMPOWERED,
    reason => "You need $who permissions to change this field.",
  };
}

sub sanitize_create {
  my ($self, $args) = @_;
  my $params = $args->{params};

  foreach my $field (keys %CREATE_DEFAULT_PARAM) {
    next if $self->can_set_field($field, $args);
    $params->{$field} = Bugzilla->params->{$CREATE_DEFAULT_PARAM{$field}};
  }
}

1;
