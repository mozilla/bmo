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

use Bugzilla::API::V1::Util;

my $util = 'Bugzilla::API::V1::Util';

like($util->type('dateTime', '2026-06-19 04:13:38'),
  qr/^2026-06-1[89]T\d\d:\d\d:\d\dZ$/, 'a valid date comes back as ISO 8601');

is($util->type('dateTime', ''),    '',    'an empty date is an empty string');
is($util->type('dateTime', undef), undef, 'an undefined date is null');

# Bug 2089049: GetBugActivity joins two activity rows for the same date field
# in one changeset into a single string that datetime_from() can't parse.
my $joined = '2026-06-19 04:13:38 2026-06-19 04:13:38';
is($util->type('dateTime', $joined),
  $joined, 'an unparseable date is returned as is instead of dying');

done_testing;
