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
use Bugzilla::Test::MockParams (confirmuniqueusermatch => 1);
use Bugzilla::Test::Util qw(create_user);
use Bugzilla::Constants;
use Bugzilla::User;
use Test2::V0;

# A web service caller can't be shown the user match confirmation page: every
# match it would ask to confirm is an error.

create_user('automation@bmo.tld', '*');
create_user('xavier@bmo.test',    '*');
create_user('alice1@bmo.test',    '*');
create_user('alice2@bmo.test',    '*');
Bugzilla->set_user(Bugzilla::User->super_user);
Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
Bugzilla->error_mode(ERROR_MODE_TEST);

sub match_needinfo_from {
  my ($value) = @_;
  my $data = {needinfo_from => $value};
  Bugzilla::User::match_field({needinfo_from => {type => 'multi'}}, $data);
  return $data->{needinfo_from};
}

is(match_needinfo_from('xavier@bmo.test'),
  ['xavier@bmo.test'], 'an exact login matches');
like(dies { match_needinfo_from('xavier') },
  qr/user_match_too_many/, 'a single fuzzy match');
like(dies { match_needinfo_from('alice') },
  qr/user_match_too_many/, 'several matches');
like(dies { match_needinfo_from('nobody-zz') },
  qr/user_match_too_many/, 'no match');

# Without confirmuniqueusermatch, the web UI accepts a single fuzzy match, and
# so does the API. The error only names the fields it couldn't match.
Bugzilla->params->{confirmuniqueusermatch} = 0;
is(match_needinfo_from('xavier'),
  ['xavier@bmo.test'], 'a single fuzzy match, without confirmation');
my $error = dies {
  Bugzilla::User::match_field(
    {cc => {type => 'multi'}, needinfo_from => {type => 'multi'}},
    {cc => 'xavier',          needinfo_from => 'alice'});
};
like($error, qr/needinfo_from/,
  'the error names the field with several matches');
unlike($error, qr/'cc'/, 'but not the field with a single fuzzy match');

done_testing;
