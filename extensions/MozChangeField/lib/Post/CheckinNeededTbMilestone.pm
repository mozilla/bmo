# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MozChangeField::Post::CheckinNeededTbMilestone;

use 5.10.1;
use Moo;

use Bugzilla::Error;

use constant PRODUCTS =>
  {map { $_ => 1 } ('Thunderbird', 'MailNews Core', 'Calendar')};

use constant KEYWORD => 'checkin-needed-tb';

sub _check_milestone {
  my ($bug) = @_;
  my $product = $bug->product_obj;

  return if !PRODUCTS->{$product->name};
  return if !$bug->has_keyword(KEYWORD);

  # The product's default milestone (normally '---') means 'not set'.
  return if $bug->target_milestone ne $product->default_milestone;

  ThrowUserError('mozchangefield_checkin_needed_tb_milestone',
    {keyword => KEYWORD});
}

sub evaluate_create {
  my ($self, $args) = @_;
  _check_milestone($args->{bug});
}

sub evaluate_change {
  my ($self, $args) = @_;
  my $changes = $args->{changes};

  # Only enforce on a save that touches one of three fields, so bugs
  # already in this state don't block unrelated edits.
  return
       if !exists $changes->{keywords}
    && !exists $changes->{target_milestone}
    && !exists $changes->{product};

  _check_milestone($args->{bug});
}

1;
