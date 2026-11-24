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
use Test::Mojo;

# The extension routes moved off the legacy REST server answer the CORS
# preflight, without logging in, as the legacy server did.
my $t = Test::Mojo->new('Bugzilla::App');

my %allow = (
  '/invalid_bug_helper/close/1'             => 'POST',
  '/bitly/shorten'                          => 'GET',
  '/bitly/list'                             => 'GET',
  '/prod_comp_search/find/fire'             => 'GET',
  '/prod_comp_search/frequent'              => 'GET',
  '/editcomments/comment'                   => 'GET',
  '/editcomments/comment/1'                 => 'GET, PUT',
  '/editcomments/revision'                  => 'PUT',
  '/component-watching'                     => 'GET, POST',
  '/component-watching/1'                   => 'DELETE, GET',
  '/bug_interest_unmark'                    => 'PUT',
  '/mydashboard/bug_interest_unmark'        => 'PUT',
  '/mydashboard/run_bug_query'              => 'GET',
  '/mydashboard/run_flag_query'             => 'GET',
  '/mydashboard/run_last_changes'           => 'GET',
  '/phabbugz/check_bug/1/2'                 => 'GET',
  '/phabbugz/check_enter_bug/Firefox/2'     => 'GET',
  '/phabbugz/bug_revisions/1'               => 'GET',
  '/phabbugz/user/2'                        => 'GET',
  '/review/suggestions'                     => 'GET',
  '/review/suggestions/1'                   => 'GET',
  '/review/suggestions/Firefox/General/Sub' => 'GET',
  '/review/flag_activity'                   => 'GET',
  '/review/flag_activity/type_name/review'  => 'GET',
  '/bug_modal/initial_field_values'         => 'GET',
  '/bug_modal/product_info'                 => 'GET',
  '/bug_modal/edit/1'                       => 'GET',
  '/bug_modal/cc/1'                         => 'GET',
  '/bug_modal/comment_tags/1'               => 'GET',
  '/bug_modal/new_product/1'                => 'GET',
  '/bug_modal/update_comment_tags/1'        => 'PUT',
);

foreach my $path (sort keys %allow) {
  $t->options_ok("/rest$path")
    ->status_is(200)
    ->header_is('Allow' => $allow{$path});
  $t->header_is('Access-Control-Allow-Methods' => $allow{$path})
    ->header_is('Access-Control-Allow-Origin'  => '*');
}

done_testing;
