# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MozChangeField::Pre::CheckinNeededTB;

use 5.10.1;

use Moo;

use Bugzilla::Error;

use constant CHECKIN_KEYWORD => 'checkin-needed-tb';
use constant PRODUCTS        => ('Calendar', 'MailNews Core', 'Thunderbird');

sub evaluate_set_all {
  my ($self, $args) = @_;

  my $bug    = $args->{bug};
  my $params = $args->{params};

  my $product
    = exists $params->{product} ? $params->{product} : $bug->product_obj->name;
  return unless grep { $_ eq $product } PRODUCTS;

  my $keyword_params = $params->{keywords};
  return unless $keyword_params;

  # This rule only applies when checkin-needed-tb is newly added.
  return if $bug->has_keyword(CHECKIN_KEYWORD);

  my $keyword_added;
  if (exists $keyword_params->{set}) {
    $keyword_added = _contains_checkin_keyword($keyword_params->{set});
  }
  else {
    $keyword_added
      = _contains_checkin_keyword($keyword_params->{add})
      && !_contains_checkin_keyword($keyword_params->{remove});
  }
  return unless $keyword_added;

  my $milestone = exists $params->{target_milestone}
    ? $params->{target_milestone}
    : $bug->target_milestone;

  if (!defined $milestone || $milestone eq '' || $milestone eq '---') {
    ThrowUserError('mozchangefield_checkin_needed_tb_requires_milestone');
  }
}

sub _contains_checkin_keyword {
  my ($keywords) = @_;
  return 0 unless defined $keywords;

  my @keywords
    = ref $keywords eq 'ARRAY' ? @$keywords : split(/[\s,]+/, $keywords);

  return scalar grep { lc($_) eq CHECKIN_KEYWORD } @keywords;
}

1;
