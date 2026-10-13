#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST Bug.create() and Bug.update() with  #
# DATE and DATETIME custom fields                   #
# POST /rest/bug                                    #
# PUT /rest/bug/<id>                                #
#####################################################

# FIELD_TYPE_DATE custom fields must be passed through to the Bug object as
# YYYY-MM-DD and returned in that same format, so a value read from the API
# can be sent back unchanged. FIELD_TYPE_DATETIME custom fields must still be
# converted from and to ISO 8601 by the REST server. See bug 2074690.

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util qw(get_config);
use QA::Tests qw(create_bug_fields);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

use constant DATE_FIELD     => 'cf_qa_date';
use constant DATETIME_FIELD => 'cf_qa_datetime';

my $config  = get_config();
my $api_key = $config->{editbugs_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

sub check_bug_dates {
  my ($bug_id, $date, $datetime, $desc) = @_;
  my $fields = join(',', DATE_FIELD, DATETIME_FIELD);
  $t->get_ok(
    $url . "rest/bug/$bug_id?include_fields=$fields" => api_headers($api_key))
    ->status_is(200)
    ->json_is('/bugs/0/' . DATE_FIELD, $date,
    "$desc: date field has the right value")
    ->json_is('/bugs/0/' . DATETIME_FIELD, $datetime,
    "$desc: datetime field has the right value");
}

###############################
# Create with both field types #
###############################

my $new_bug = create_bug_fields($config);
$new_bug->{+DATE_FIELD}     = '2026-01-15';
$new_bug->{+DATETIME_FIELD} = '2026-01-15T12:15:00Z';

$t->post_ok($url . 'rest/bug' => api_headers($api_key) => json => $new_bug)
  ->status_is(200)->json_has('/id');
my $bug_id = $t->tx->res->json->{id};

check_bug_dates($bug_id, '2026-01-15', '2026-01-15T12:15:00Z', 'After create');

###############################
# Update with both field types #
###############################

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {DATE_FIELD, '2026-02-20', DATETIME_FIELD, '2026-02-20T08:45:00Z'})
  ->status_is(200);

check_bug_dates($bug_id, '2026-02-20', '2026-02-20T08:45:00Z', 'After update');

#############################################
# Date fields still reject a time component #
#############################################

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {DATE_FIELD, '2026-03-01 10:00:00'})->status_is(400)
  ->json_is('/code' => 56)
  ->json_like('/message' => qr/is not a legal date/);

check_bug_dates($bug_id, '2026-02-20', '2026-02-20T08:45:00Z',
  'After rejected update');

# ISO 8601 with a time is rejected too. Date fields are returned as plain
# YYYY-MM-DD, so this is not a value a client would read back from the API.
$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {DATE_FIELD, '2026-03-01T00:00:00Z'})->status_is(400)
  ->json_is('/code' => 56)
  ->json_like('/message' => qr/is not a legal date/);

check_bug_dates($bug_id, '2026-02-20', '2026-02-20T08:45:00Z',
  'After rejected ISO 8601 update');

##########################################
# Read-modify-write round trip is stable #
##########################################

my $read_url = $url . "rest/bug/$bug_id?include_fields=" . DATE_FIELD;
$t->get_ok($read_url => api_headers($api_key))->status_is(200);
my $read_back = $t->tx->res->json->{bugs}->[0]->{+DATE_FIELD};
ok(defined $read_back, 'Date field value was read back from the API');

$t->put_ok($url
    . "rest/bug/$bug_id" => api_headers($api_key) => json =>
    {DATE_FIELD, $read_back})->status_is(200);

check_bug_dates($bug_id, '2026-02-20', '2026-02-20T08:45:00Z',
  'After writing back the value read from the API');

done_testing();
