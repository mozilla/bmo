#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for the live @mention warning endpoint of    #
# the Needinfo extension:                           #
# POST /rest/needinfo/mentions                      #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use QA::Util       qw(get_config random_string);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config   = get_config();
my $url      = Bugzilla->localconfig->urlbase;
my $admin    = api_headers($config->{admin_user_api_key});
my $no_privs = api_headers($config->{unprivileged_user_api_key});
my $endpoint = $url . 'rest/needinfo/mentions';

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# Mentions are looked up by the nickname in the real name, so create a user
# that has one.
my $nick = 'mention' . lc random_string(8);
$t->post_ok(
  $url
    . 'rest/user' => $admin => json => {
    email     => "$nick\@webservice.test",
    full_name => "Mention Target [:$nick]",
    password  => 'UiX1Shuuchid',
    }
)->status_is(201);

my $expected
  = [{nick => $nick, name => "Mention Target [:$nick]", needinfo => 1}];

# A comment on an existing bug.
$t->post_ok($endpoint => $admin => json =>
    {text => "\@$nick can you look? cc \@admin", id => 'public_bug'})
  ->status_is(200)
  ->json_is(
  '/mentions' => $expected,
  'the mentioned user would be needinfod, the commenter is skipped'
  );

$t->post_ok($endpoint => $admin => json =>
    {text => "`\@$nick`\n> \@$nick\nfoo\@$nick.test", id => 'public_bug'})
  ->status_is(200)
  ->json_is(
  '/mentions' => [],
  'mentions in code, quotes and emails are ignored'
  );

$t->post_ok($endpoint => $admin => json =>
    {text => '@nobody-has-this-nick', id => 'public_bug'})
  ->status_is(200)
  ->json_is('/mentions' => [], 'unknown nicknames are ignored');

$t->post_ok(
  $endpoint => $admin => json => {text => 'no mentions here', id => 'public_bug'})
  ->status_is(200)
  ->json_is('/mentions' => [], 'no mentions without an @');

# Only editbugs users trigger mentions.
$t->post_ok($endpoint => $no_privs => json =>
    {text => "\@$nick can you look?", id => 'public_bug'})
  ->status_is(200)
  ->json_is(
  '/mentions' => [],
  'nobody is needinfod by a user without editbugs'
  );

# The initial comment of a bug being filed.
$t->post_ok(
  $endpoint => $admin => json => {
    text      => "\@$nick can you look?",
    product   => 'TestProduct',
    component => 'TestComponent',
    groups    => [],
  }
)->status_is(200)->json_is(
  '/mentions' => $expected,
  'new bug: the mentioned user would be needinfod'
);

$t->post_ok($endpoint => $admin => json =>
    {text => "\@$nick can you look?", product => 'TestProduct'})
  ->status_is(200)
  ->json_is('/mentions' => $expected, 'new bug: the component is optional');

# Errors.
$t->post_ok($endpoint => $admin => json => {text => '@admin'})
  ->status_isnt(200)
  ->json_like('/message' => qr/id, product/);
$t->post_ok($endpoint => $admin => json => {id => 'public_bug'})
  ->status_isnt(200)
  ->json_like('/message' => qr/text/);
$t->post_ok($endpoint => $admin => json =>
    {text => '@admin', id => {condition => 'bug_id = ?', values => [1]}})
  ->status_is(400)
  ->json_like('/message' => qr/id must be a single value/);
$t->post_ok($endpoint => api_headers(undef) => json =>
    {text => "\@$nick", id => 'public_bug'})
  ->status_isnt(200)
  ->json_like('/message' => qr/You must log in/);

done_testing();
