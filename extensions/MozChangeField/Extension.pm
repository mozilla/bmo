# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MozChangeField;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Extension);

use Bugzilla::Constants;
use Bugzilla::Logging;

use Bugzilla::Extension::MozChangeField::Pre::CanConfirm;
use Bugzilla::Extension::MozChangeField::Pre::CommentClosedBugs;
use Bugzilla::Extension::MozChangeField::Pre::CustomField;
use Bugzilla::Extension::MozChangeField::Pre::Graveyard;
use Bugzilla::Extension::MozChangeField::Pre::Reopen;
use Bugzilla::Extension::MozChangeField::Pre::TypePriSevEditbugs;

my @pre_instances = (
  Bugzilla::Extension::MozChangeField::Pre::CanConfirm->new,
  Bugzilla::Extension::MozChangeField::Pre::CommentClosedBugs->new,
  Bugzilla::Extension::MozChangeField::Pre::CustomField->new,
  Bugzilla::Extension::MozChangeField::Pre::Graveyard->new,
  Bugzilla::Extension::MozChangeField::Pre::Reopen->new,
  Bugzilla::Extension::MozChangeField::Pre::TypePriSevEditbugs->new,
);

use Bugzilla::Extension::MozChangeField::Post::SeverityS1PriorityP1;
use Bugzilla::Extension::MozChangeField::Post::ClearTrackingPriorityS1;

#use Bugzilla::Extension::MozChangeField::Post::CommentOnSeverity;
use Bugzilla::Extension::MozChangeField::Post::SetTrackingSeverityS1;
use Bugzilla::Extension::MozChangeField::Post::TypePriSevEditbugs;
use Bugzilla::Extension::MozChangeField::Post::RegressedByTypeKeyword;
use Bugzilla::Extension::MozChangeField::Post::CheckinNeededTbMilestone;

my @post_instances = (
  Bugzilla::Extension::MozChangeField::Post::SeverityS1PriorityP1->new,
  Bugzilla::Extension::MozChangeField::Post::ClearTrackingPriorityS1->new,

  #Bugzilla::Extension::MozChangeField::Post::CommentOnSeverity->new,
  Bugzilla::Extension::MozChangeField::Post::SetTrackingSeverityS1->new,
  Bugzilla::Extension::MozChangeField::Post::TypePriSevEditbugs->new,
  Bugzilla::Extension::MozChangeField::Post::RegressedByTypeKeyword->new,
  Bugzilla::Extension::MozChangeField::Post::CheckinNeededTbMilestone->new,
);

our $VERSION = '0.1';

sub bug_check_can_change_field {
  my ($self, $args) = @_;

  _populate_permissions($args);

  foreach my $instance (@pre_instances) {
    next if !$instance->can('evaluate_change');
    my $result = $instance->evaluate_change($args);
    push @{$args->{priv_results}}, $result if defined $result;
  }
}

sub bug_update_before_logging {
  my ($self, $args) = @_;

  _populate_permissions($args);

  foreach my $instance (@post_instances) {
    next if !$instance->can('evaluate_change');
    $instance->evaluate_change($args);
  }
}

sub bug_end_of_create {
  my ($self, $args) = @_;

  _populate_permissions($args);

  foreach my $instance (@post_instances) {
    next if !$instance->can('evaluate_create');
    $instance->evaluate_create($args);
  }
}

sub _populate_permissions {
  my ($args) = @_;
  my $user = Bugzilla->user;

  # Some modules need these permissions to function so only look up once
  $args->{canconfirm}
    = $user->in_group('canconfirm', $args->{bug}->{'product_id'});
  $args->{editbugs} = $user->in_group('editbugs', $args->{bug}->{'product_id'});
}

__PACKAGE__->NAME;

__END__

=head1 NAME

Bugzilla::Extension::MozChangeField - An extension to support
customizing how field permissions are handle to support the
Mozilla bug workflow.

=head1 SYNOPSIS

  use Bugzilla::Extension::MozChangeField::Pre::BugStatus;

  my $bug_status_instance = Bugzilla::Extension::MozChangeField::BugStatus->new,

  sub bug_check_can_change_field {
    my ($self, $args) = @_;
    my $result = $bug_status_instance->evaluate_change($args);
    push @{$args->{priv_results}}, $result if defined $result;
  }

=head1 DESCRIPTION

Bugzilla::Extension::MozChangeField is a Bugzilla extension that customizes
the default behavior of Bugzilla.

This extension primarily uses the C<bug_check_can_change_field> hook. This
hook controls what fields users are allowed to change. This hook adds code
for site-specific policy changes and other customizations that support the
Mozilla bug workflow.

This hook is only executed if the field's new and old values differ.

Any denies take priority over any allows. So, if one module explicitly denies
a change but then another allows the change, the other module's deny will
override the allow. Same goes for other extensions in use by Bugzilla that
may also be using C<bug_check_can_change_field>.

Each smaller supporting module defines a function called C<evaluate_change>
which is called in a defined order. The function is passed the following
parameters in a hash as the first parameter.

Params:

=over

=item C<bug>

L<Bugzilla::Bug> - The current bug object that this field is changing on.

=item C<field>

The name (from the C<fielddefs> table) of the field that we are checking.

=item C<new_value>

The new value that the field is being changed to.

=item C<old_value>

The old value that the field is being changed from.

=item C<canconfirm>

Whether the current user is in the C<canconfirm> group.

=item C<editbugs>

Whether the current user is in the C<editbugs> group.

=back

Each module will either return C<undef> if the current change is not
applicable to it, or a hash containing the result of whether the user
is allowed to make the change or not. If the result is a hash, it
is added to the C<priv_results> list explained below. The hash should
contain a key called C<privs> and optionally, a key called C<reason>.

=over

=item C<privs>

The below values are actually constants defined in L<Bugzilla::Constants>.

=over

=item C<PRIVILEGES_REQUIRED_NONE>

No privileges required. This explicitly B<allows> a change.

=item C<PRIVILEGES_REQUIRED_REPORTER>

User is not the reporter, assignee or an empowered user, so B<deny>.

=item C<PRIVILEGES_REQUIRED_ASSIGNEE>

User is not the assignee or an empowered user, so B<deny>.

=item C<PRIVILEGES_REQUIRED_EMPOWERED>

User is not a sufficiently empowered user, so B<deny>.

=back

=item C<reason>

String containing a more detailed reason of why the change was denied if needed.

=back

=head2 C<priv_results>

This is how you explicitly allow or deny a change. You should only
push something into this array if you want to explicitly allow or explicitly
deny the change, and thus skip all other permission checks that would otherwise
happen after this hook is called. If you don't care about the field change,
then don't push anything into the array.

=cut
