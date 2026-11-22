# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MozChangeField::Pre::KeywordsCanconfirm;

use 5.10.1;
use Moo;

use Bugzilla::Constants;

# Keywords are a triage tool, so only users with 'canconfirm' or 'editbugs'
# may add or remove them. Without this the reporter could change them, as core
# grants reporters PRIVILEGES_REQUIRED_REPORTER.
sub _can_set_keywords {
  my ($args) = @_;
  return $args->{canconfirm} || $args->{editbugs};
}

sub evaluate_change {
  my ($self, $args) = @_;

  return undef if $args->{'field'} ne 'keywords';
  return undef if _can_set_keywords($args);

  return {
    result => PRIVILEGES_REQUIRED_EMPOWERED,
    reason => 'You need "canconfirm" permissions to change keywords.',
  };
}

# Silently drop keywords when a user without 'canconfirm' files a bug, the same
# way severity and priority are reset rather than rejected.
sub sanitize_create {
  my ($self, $args) = @_;
  return if _can_set_keywords($args);

  my $params = $args->{params};
  $params->{keywords} = [] if exists $params->{keywords};
}

1;
