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

use Test::More;
use Test::Mojo;

use Bugzilla;
BEGIN { Bugzilla->extensions }
use Bugzilla::Constants;
use Bugzilla::Bug;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::Test::Util qw(issue_api_key);

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $admin = Bugzilla::User->new({name => 'admin@mozilla.bugs'});
my ($product)
  = grep { $_->is_active && @{$_->components} && @{$_->versions} }
  Bugzilla::Product->get_all;
plan skip_all => 'Need an admin and a product' unless $admin && $product;

my %auth = ('X-Bugzilla-API-Key' => issue_api_key($admin->login)->api_key);
my $t    = Test::Mojo->new('Bugzilla::App');

Bugzilla->set_user($admin);
my %fields = (
  short_desc   => "BugModal API test $$",
  product      => $product->name,
  component    => $product->components->[0]->name,
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => $product->versions->[0]->name,
  comment      => 'a comment',
  cc           => [$admin->login],
);
my $bug = Bugzilla::Bug->create({%fields});
$bug->add_comment('a private comment');
$bug->update;
my ($public, $private)
  = map { $_->id } @{Bugzilla::Bug->new($bug->id)->comments}[0, 1];

# The admin isn't an insider here, so it can't add a private comment.
Bugzilla->dbh->do('UPDATE longdescs SET isprivate = 1 WHERE comment_id = ?',
  undef, $private);
my $bug_id = $bug->id;

# A bug in a group the plain user below isn't in.
my $group = Bugzilla::Group->create({
  name        => "bug-modal-api-$$",
  description => 'BugModal API test',
  isbuggroup  => 1,
});
my $secret_id = Bugzilla::Bug->create({%fields})->id;
Bugzilla->dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
  undef, $secret_id, $group->id);

# A user who isn't in the comment taggers group.
my $plain
  = Bugzilla::User->create({
  login_name => "bug-modal-api-$$\@bmo.tld", cryptpassword => '*',
  });
my %plain_auth
  = ('X-Bugzilla-API-Key' => issue_api_key($plain->login)->api_key);
Bugzilla->clear_request_cache;

# initial_field_values and product_info
$t->get_ok('/rest/bug_modal/initial_field_values')
  ->status_is(200)
  ->json_has('/products')
  ->json_has('/keywords')
  ->json_has('/default_bug_types/0', 'initial field values, signed out');
my $name = $product->name;
$t->get_ok('/rest/bug_modal/product_info' => form => {product => $name})
  ->status_is(200)
  ->json_is('/components/0/name' => $product->components->[0]->name)
  ->json_has('/versions/0/name', 'product info');
$t->get_ok('/rest/bug_modal/product_info?product=No.Such%20Product')
  ->json_is('/error' => 1)
  ->json_like('/message' => qr/No\.Such Product/, 'unknown product');
$t->get_ok(
  '/rest/bug_modal/product_info' => form => {product => [$name, $name]})
  ->json_is('/code' => 50, 'product_info refuses more than one product');

# edit, cc
$t->get_ok("/rest/bug_modal/edit/$bug_id" => \%auth)
  ->status_is(200)
  ->json_is('/options/component/0/name' => $bug->component)
  ->json_has('/options/bug_type/0/name')
  ->json_has('/keywords', 'edit options');
$t->get_ok("/rest/bug_modal/edit/$bug_id" => \%auth => json =>
    {id => {condition => 'bug_id = ?', values => [$bug_id]}})
  ->status_is(200)
  ->json_is(
  '/options/component/0/name' => $bug->component,
  'on a GET, an id in the body is ignored'
  );
$t->get_ok("/rest/bug_modal/cc/$bug_id" => \%auth)
  ->status_is(200)
  ->json_like('/html' => qr/data-user-id="${\ $admin->id }"/, 'cc list html');
$t->get_ok('/rest/bug_modal/cc/999999999')
  ->json_is('/error' => 1, 'unknown bug');
$t->get_ok("/rest/bug_modal/cc/$bug_id?id=999999999" => \%auth)
  ->status_is(200)
  ->json_has('/html', 'on a GET, the id in the path wins');

# comment_tags, update_comment_tags
$t->get_ok("/rest/bug_modal/comment_tags/$public")
  ->status_is(200)
  ->json_has('/html', 'comment tags html');
$t->get_ok("/rest/bug_modal/comment_tags/$private")
  ->json_is('/error' => 1)
  ->json_like(
  '/message' => qr/private/,
  'private comment hidden when signed out'
  );
$t->put_ok(
  "/rest/bug_modal/update_comment_tags/$public" => json => {add => ['bmtag']})
  ->status_is(401, 'update_comment_tags needs a login');
$t->put_ok("/rest/bug_modal/update_comment_tags/$public" => \%auth => json =>
    {add => ['bmtag']})
  ->status_is(200)
  ->json_like('/html' => qr/bmtag/, 'tag added');
$t->put_ok("/rest/bug_modal/update_comment_tags/$public" => \%auth => json =>
    {remove => ['bmtag']})
  ->status_is(200)
  ->json_unlike('/html' => qr/bmtag/, 'tag removed');
$t->put_ok("/rest/bug_modal/update_comment_tags/$public" => \%auth => json =>
    {add => 'bmtag2'})
  ->status_is(200)
  ->json_like('/html' => qr/bmtag2/, 'a single tag to add, not in a list');
$t->put_ok("/rest/bug_modal/update_comment_tags/$public" => \%auth => json =>
    {add => {tag => 'bmtag3'}})
  ->status_is(400)
  ->json_like(
  '/message' => qr/add must be a value or a list of values/,
  'a hash of tags is refused'
  );
$t->put_ok("/rest/bug_modal/update_comment_tags/$public" => \%auth => json =>
    {id => {condition => 'comment_id = ?', values => [$public]}})
  ->json_is('/error' => 1)
  ->json_like('/message' => qr/numeric/, 'a hash id is refused');
$t->put_ok(
  "/rest/bug_modal/update_comment_tags/$public" => \%plain_auth => json =>
    {add => ['bmtag']})->json_is('/error' => 1)->json_like(
  '/message' => qr/aren't a member of the '[^']+' group/,
  'only comment taggers can tag'
    );

# new_product
$t->get_ok(
  "/rest/bug_modal/new_product/$bug_id" => \%auth => form => {product => $name})
  ->status_is(200)
  ->json_is('/component/0/name'     => $bug->component)
  ->json_is('/component/0/selected' => Mojo::JSON::true)
  ->json_has('/version/0/name')
  ->json_has('/target_milestone/0/name')
  ->json_has('/groups', 'fields for the same product');
$t->get_ok("/rest/bug_modal/new_product/$bug_id" => \%auth)
  ->json_is('/error' => 1, 'product is required');
$t->get_ok("/rest/bug_modal/new_product/$bug_id" => \%auth => form =>
    {product => [$name, $name]})
  ->json_is('/code' => 50, 'new_product refuses more than one product');

# edit, cc and new_product on a bug the caller can't see
foreach my $path (qw(edit cc new_product)) {
  $t->get_ok("/rest/bug_modal/$path/$secret_id" => \%plain_auth => form =>
      {product => $name})->json_is('/error' => 1)->json_like(
    '/message' => qr/not authorized to access bug $secret_id/,
    "$path refuses a hidden bug"
      );
}

done_testing;
