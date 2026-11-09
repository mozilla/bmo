#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla::Test::MockLocalconfig (urlbase => 'http://bmo.test');
use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;

use Test2::V0;

use Bugzilla::API::V1::Bug;

# Bug 2089049 / 2089526: history added/removed are documented as strings, so
# they come back as the raw activity values whatever the field's type.
my $controller = Bugzilla::API::V1::Bug->new;
my $joined     = '2026-06-19 2026-06-20';

my $item = $controller->changeset_to_hash({
  when    => '2026-06-19 04:13:38',
  who     => 'tester@mozilla.test',
  changes => [
    {fieldname => 'deadline',       removed => '',     added => $joined},
    {fieldname => 'remaining_time', removed => '1.50', added => '0.00'},
  ],
});

my ($deadline, $remaining) = @{$item->{changes}};

is($deadline->{field_name}, 'deadline', 'date field name');
is($deadline->{added},      $joined,    'joined date values come back as is');
is($deadline->{removed},    '',         'empty date value is an empty string');

is($remaining->{field_name}, 'remaining_time', 'numeric field name');
is($remaining->{removed},    '1.50', 'numeric value is not converted');
is($remaining->{added},      '0.00', 'zero numeric value is not converted');

like(
  $item->{when},
  qr/^2026-06-1[89]T\d\d:\d\d:\d\dZ$/,
  'changeset when is still an ISO 8601 dateTime'
);

done_testing;
