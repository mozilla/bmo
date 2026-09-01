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

use lib qw(. lib local/lib/perl5);

use Test::More;

require './extensions/MozChangeField/lib/Pre/CheckinNeededTB.pm';

{
  package Local::Product;

  sub new {
    my ($class, $name) = @_;
    return bless {name => $name}, $class;
  }

  sub name {
    return $_[0]->{name};
  }
}

{
  package Local::Bug;

  sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
  }

  sub product_obj {
    return Local::Product->new($_[0]->{product});
  }

  sub has_keyword {
    return $_[0]->{has_keyword};
  }

  sub target_milestone {
    return $_[0]->{milestone};
  }
}

package main;

my $rule
  = Bugzilla::Extension::MozChangeField::Pre::CheckinNeededTB->new;

sub evaluate_rule {
  my (%args) = @_;

  my $bug = Local::Bug->new(
    product     => $args{product} || 'Thunderbird',
    has_keyword => $args{has_keyword} || 0,
    milestone   => exists $args{milestone} ? $args{milestone} : '---',
  );

  eval {
    $rule->evaluate_set_all({
      bug    => $bug,
      params => $args{params},
    });
  };

  return $@;
}

{
  no warnings qw(once redefine);

  local
    *Bugzilla::Extension::MozChangeField::Pre::CheckinNeededTB::ThrowUserError
    = sub { die "$_[0]\n"; };

  foreach my $product ('Calendar', 'MailNews Core', 'Thunderbird') {
    like(
      evaluate_rule(
        product => $product,
        params  => {keywords => {add => ['checkin-needed-tb']}},
      ),
      qr/mozchangefield_checkin_needed_tb_requires_milestone/,
      "Adding checkin-needed-tb without a milestone is rejected for $product"
    );
  }

  is(
    evaluate_rule(
      milestone => 'Thunderbird 153',
      params    => {keywords => {add => ['checkin-needed-tb']}},
    ),
    '',
    'An existing target milestone allows the keyword'
  );

  is(
    evaluate_rule(
      params => {
        keywords         => {add => ['checkin-needed-tb']},
        target_milestone => 'Thunderbird 153',
      },
    ),
    '',
    'The keyword and target milestone can be set together'
  );

  is(
    evaluate_rule(
      product => 'Firefox',
      params  => {keywords => {add => ['checkin-needed-tb']}},
    ),
    '',
    'Other products are unaffected'
  );

  is(
    evaluate_rule(
      has_keyword => 1,
      params      => {keywords => {add => ['another-keyword']}},
    ),
    '',
    'A bug that already has checkin-needed-tb is unaffected'
  );

  like(
    evaluate_rule(
      params => {keywords => {set => ['checkin-needed-tb']}},
    ),
    qr/mozchangefield_checkin_needed_tb_requires_milestone/,
    'Setting the complete keyword list is also validated'
  );
}

done_testing();
