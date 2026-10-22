#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.update_attachment()     #
# PUT /rest/bug/attachment/<attachment_id>           #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use MIME::Base64   qw(encode_base64);
use QA::Util       qw(get_config);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config        = get_config();
my $url           = Bugzilla->localconfig->urlbase;
my $admin_api_key = $config->{admin_user_api_key};
my $headers       = api_headers($admin_api_key);

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

sub new_attachment {
  my ($summary) = @_;
  $t->post_ok(
    $url
      . 'rest/bug/public_bug/attachment' => $headers => json => {
      summary      => $summary,
      file_name    => 'update.txt',
      content_type => 'text/plain',
      data         => encode_base64('update test', ''),
      }
  )->status_is(201);
  my ($id) = keys %{$t->tx->res->json->{attachments}};
  return $id;
}

my $first  = new_attachment('first attachment');
my $second = new_attachment('second attachment');

# The id in the path is used when the body has no ids.
$t->put_ok($url
    . "rest/bug/attachment/$first" => $headers => json =>
    {summary => 'first renamed', is_obsolete => 1, comment => 'obsoleted'})
  ->status_is(200)
  ->json_is('/attachments/0/id'                        => $first)
  ->json_is('/attachments/0/changes/summary/removed'   => 'first attachment')
  ->json_is('/attachments/0/changes/summary/added'     => 'first renamed')
  ->json_is('/attachments/0/changes/is_obsolete/added' => '1')
  ->json_like('/attachments/0/last_change_time' => qr/^\d{4}-\d\d-\d\dT.*Z$/);

# ids in the body win over the id in the path, as on the legacy REST server.
$t->put_ok($url
    . "rest/bug/attachment/$first" => $headers => json =>
    {ids => [$second], summary => 'second renamed'})
  ->status_is(200)
  ->json_is('/attachments/0/id' => $second);
is(scalar @{$t->tx->res->json->{attachments}}, 1,
  'Only the body id is updated');

# Credentials in the query string are not taken for attachment fields.
$t->put_ok($url
    . "rest/bug/attachment/$second?api_key=$admin_api_key" => {} => json =>
    {summary => 'renamed with api_key'})
  ->status_is(200)
  ->json_is('/attachments/0/changes/summary/added' => 'renamed with api_key');

# Both attachments can be fetched together: the path id is added to the query.
$t->get_ok(
  $url . "rest/bug/attachment/$first?attachment_ids=$second" => $headers)
  ->status_is(200)
  ->json_is("/attachments/$first/summary"     => 'first renamed')
  ->json_is("/attachments/$first/is_obsolete" => 1)
  ->json_is("/attachments/$second/summary"    => 'renamed with api_key');

# Errors
$t->put_ok($url
    . "rest/bug/attachment/$first" => api_headers(undef) => json =>
    {summary => 'logged out'})
  ->status_isnt(200)
  ->json_like('/message' => qr/You must log in/);

$t->put_ok(
  $url . "rest/bug/attachment/$first" => $headers => json => {bogus => 1})
  ->status_isnt(200)
  ->json_like('/message' => qr/set_bogus/);

$t->put_ok($url
    . 'rest/bug/attachment/999999999' => $headers => json =>
    {summary => 'no such attachment'})
  ->status_isnt(200)
  ->json_like('/message' => qr/999999999/);

$t->options_ok($url . "rest/bug/attachment/$first")
  ->status_is(200)
  ->header_is('Allow' => 'GET, PUT');
$t->options_ok($url . 'rest/bug/public_bug/attachment')
  ->status_is(200)
  ->header_is('Allow' => 'GET, POST');

done_testing();
