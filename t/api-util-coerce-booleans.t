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
use Mojo::JSON qw(decode_json);

use Bugzilla::API::V1::Util qw(coerce_booleans);

my $json
  = decode_json('{"a": true, "b": false, "c": "TRUE", "d": "0", "e": null}');
is(coerce_booleans($json, qw(a b c d e missing)), undef, 'booleans pass');
is($json->{a},        T(),    'a JSON true is kept as a true value');
is($json->{b},        F(),    'a JSON false is kept as a false value');
is([@$json{qw(c d)}], [1, 0], 'strings become 1 or 0');
is($json->{e},        undef,  'null is left alone');

# Anything else is refused, including arrays and hashes, which would otherwise
# be taken as true.
foreach my $bad ('"maybe"', '"2"', '2', '[]', '{}', '[true]') {
  my $params = decode_json(qq({"flag": $bad}));
  is(
    coerce_booleans($params, 'flag'),
    'flag must be true or false',
    "$bad is refused"
  );
}

done_testing;
