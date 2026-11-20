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
plan skip_all => 'Need an edit-comments admin and a product'
  unless $admin && $admin->is_edit_comments_admin && $product;

my $plain
  = Bugzilla::User->create({
  login_name => "editcomments-api-$$\@bmo.tld", cryptpassword => '*',
  });

Bugzilla->set_user($admin);
my %fields = (
  short_desc   => "EditComments API test $$",
  product      => $product->name,
  component    => $product->components->[0]->name,
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => $product->versions->[0]->name,
);
my $bug = Bugzilla::Bug->create({%fields, comment => 'first comment'});
$bug->add_comment('second comment');
$bug->add_comment('private comment');
$bug->update;
my ($c0, $c1, $c2) = map { $_->id } @{Bugzilla::Bug->new($bug->id)->comments};

# The admin isn't an insider here, so it can't add a private comment.
Bugzilla->dbh->do('UPDATE longdescs SET isprivate = 1 WHERE comment_id = ?',
  undef, $c2);

# A bug in a group the plain user isn't in.
my $group = Bugzilla::Group->create({
  name        => "editcomments-api-$$",
  description => 'EditComments API test',
  isbuggroup  => 1,
});
my $secret = Bugzilla::Bug->create({%fields, comment => 'secret comment'});
Bugzilla->dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
  undef, $secret->id, $group->id);
my $s0  = $secret->comments->[0]->id;
my $sid = $secret->id;
Bugzilla->clear_request_cache;

my %admin_auth
  = ('X-Bugzilla-API-Key' => issue_api_key($admin->login)->api_key);
my %plain_auth
  = ('X-Bugzilla-API-Key' => issue_api_key($plain->login)->api_key);
my $t = Test::Mojo->new('Bugzilla::App');

# GET
$t->get_ok("/rest/editcomments/comment/$c0")
  ->status_is(200)
  ->json_is("/comments/$c0" => 'first comment', 'one comment by path');
$t->get_ok('/rest/editcomments/comment' => form => {comment_ids => [$c0, $c1]})
  ->status_is(200)
  ->json_is(
  '/comments' => {$c0 => 'first comment', $c1 => 'second comment'},
  'several comments by query'
  );
$t->get_ok('/rest/editcomments/comment' => form =>
    {comment_ids => [$c0, $c1], comment_id => $c1})->status_is(200)->json_is(
  '/comments' => {$c0 => 'first comment', $c1 => 'second comment'},
  'comment_id in the query string is ignored'
    );
$t->get_ok('/rest/editcomments/comment')
  ->status_is(400)
  ->json_like('/message' => qr/comment_ids/, 'comment_ids is required');

# GET: private comments and hidden bugs
$t->get_ok("/rest/editcomments/comment/$c2" => \%plain_auth)->json_like(
  '/message' => qr/Comment id $c2 is private/,
  'a non-insider cannot read a private comment'
);
$t->get_ok("/rest/editcomments/comment/$c2")->json_like(
  '/message' => qr/Comment id $c2 is private/,
  'a signed-out user cannot read a private comment'
);
$t->get_ok("/rest/editcomments/comment/$s0" => \%plain_auth)->json_like(
  '/message' => qr/not authorized to access bug $sid/,
  'a non-member cannot read a comment on a hidden bug'
);
$t->get_ok("/rest/editcomments/comment/$s0")->json_like(
  '/message' => qr/not authorized to access bug $sid/,
  'a signed-out user cannot read a comment on a hidden bug'
);

# PUT /comment/<id>
my $comment_url = "/rest/editcomments/comment/$c1";
$t->put_ok($comment_url => json => {new_comment => 'x'})
  ->status_is(401)
  ->json_is('/code' => 410, 'login required');
$t->put_ok($comment_url => \%plain_auth => json => {new_comment => 'x'})
  ->status_isnt(200)
  ->json_like('/message' => qr/not authorized/, 'others cannot edit it');
$t->put_ok("/rest/editcomments/comment/$c2" => \%admin_auth => json =>
    {new_comment => 'x'})->status_isnt(200)->json_like(
  '/message' => qr/Comment id $c2 is private/,
  'a non-insider cannot edit a private comment'
    );
$t->put_ok("/rest/editcomments/comment/$s0" => \%plain_auth => json =>
    {new_comment => 'x'})->status_isnt(200)->json_like(
  '/message' => qr/not authorized to access bug $sid/,
  'a non-member cannot edit a comment on a hidden bug'
    );
$t->put_ok($comment_url => \%admin_auth => json =>
    {new_comment => 'x', is_hidden => 'maybe'})
  ->status_is(400)
  ->json_like('/message' => qr/is_hidden must be true or false/);
$t->put_ok($comment_url => \%admin_auth => json =>
    {new_comment => 'x', is_hidden => []})
  ->status_is(400)
  ->json_like('/message' => qr/is_hidden must be true or false/);
$t->put_ok($comment_url => \%admin_auth => json =>
    {new_comment => 'edited comment', is_hidden => 1})
  ->status_is(200)
  ->json_is('/text'  => 'edited comment')
  ->json_is('/count' => 1, 'one revision');
like($t->tx->res->json->{html}, qr/edited comment/, 'html is returned');
$t->put_ok(
  $comment_url => \%admin_auth => json => {new_comment => 'edited comment'})
  ->status_isnt(200)
  ->json_like('/message' => qr/new_comment/, 'refuses an unchanged comment');

# PUT /revision
my $dbh = Bugzilla->dbh;
my ($change_when, $is_hidden)
  = $dbh->selectrow_array(
  'SELECT change_when, is_hidden FROM longdescs_activity WHERE comment_id = ?',
  undef, $c1);
is($is_hidden, 1, 'the admin hid the old revision');

my %revision = (comment_id => $c1, change_when => $change_when, is_hidden => 0);
$t->put_ok('/rest/editcomments/revision' => \%plain_auth => json => \%revision)
  ->status_isnt(200)
  ->json_like('/message' => qr/edit_comments_admins_group/, 'admins only');
$t->put_ok('/rest/editcomments/revision' => \%admin_auth => json => \%revision)
  ->status_is(200)
  ->json_is('/is_hidden' => Mojo::JSON::false);
is(
  $dbh->selectrow_array(
    'SELECT is_hidden FROM longdescs_activity WHERE comment_id = ?',
    undef, $c1
  ),
  0,
  'the revision is shown again'
);

done_testing;
