# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use 5.10.1;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Bugzilla::Constants;
use QA::Util qw(get_config);

use Mojo::JSON qw(true);
use Mojo::Util qw(dumper);
use Test::Mojo;
use Test::More;

my $config               = get_config();
my $admin_api_key        = $config->{admin_user_api_key};
my $unprivileged_api_key = $config->{unprivileged_user_api_key};
my $unprivileged_login   = $config->{unprivileged_user_login};
my $url                  = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Create a new group for testing
my $new_group = {
  name        => 'secret-group',
  description => 'Too secret for you!',
  is_active   => true
};
$t->post_ok($url
    . 'rest/group' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    $new_group)->status_is(201)->json_has('/id');

my $group_id = $t->tx->res->json->{id};

# Make sure we can get the group details back
$t->get_ok(
  $url . "rest/group/$group_id" => {'X-Bugzilla-API-Key' => $admin_api_key})
  ->status_is(200)->json_is('/groups/0/name', 'secret-group');

# A repeated ids parameter must return every group asked for, not just the last
my $second_group = {
  name        => 'secret-group-two',
  description => 'Also too secret for you!',
  is_active   => true
};
$t->post_ok($url
    . 'rest/group' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    $second_group)->status_is(201)->json_has('/id');

my $second_group_id = $t->tx->res->json->{id};

$t->get_ok($url
    . "rest/group?ids=$group_id&ids=$second_group_id" =>
    {'X-Bugzilla-API-Key' => $admin_api_key})->status_is(200);

my @returned_ids
  = sort { $a <=> $b } map { $_->{id} } @{$t->tx->res->json->{groups}};
is_deeply(\@returned_ids, [sort { $a <=> $b } ($group_id, $second_group_id)],
  'a repeated ids parameter returns both groups');

# Create a new user and add it to the new group
my $new_user = {
  email     => 'group_test_user@mozilla.bugs',
  full_name => 'Group Test User',
  password  => 'password123456789!'
};
$t->post_ok($url
    . 'rest/user' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    $new_user)->status_is(201)->json_has('/id');

my $user_id = $t->tx->res->json->{id};

my $user_update = {groups => {add => ['secret-group']}};
$t->put_ok(
  $url . "rest/user/$user_id" => {'X-Bugzilla-API-Key' => $admin_api_key} => json => $user_update)
  ->status_is(200)->json_has('/users');

# Observe the new user is a member of the secret-group
$t->get_ok($url
    . "rest/group/$group_id?membership=1" =>
    {'X-Bugzilla-API-Key' => $admin_api_key})->status_is(200)
  ->json_is('/groups/0/name', 'secret-group');

my $result = $t->tx->res->json;
my $user_found = 0;
foreach my $user (@{$result->{groups}->[0]->{membership}}) {
  $user_found = 1 if $user->{id} == $user_id;
}
ok($user_found, "User was included in membership list of new group");

# Unprivileged user should not be able to see group 
$t->get_ok($url . "rest/group/$group_id" => {'X-Bugzilla-API-Key' => $unprivileged_api_key})
  ->status_is(400);

# Adding the unprivileged user to the can_see_groups
# group should allow seeing the group
$user_update = {groups => {add => ['can_see_groups']}};
$t->put_ok(
  $url . "rest/user/$unprivileged_login" => {'X-Bugzilla-API-Key' => $admin_api_key} => json => $user_update)
  ->status_is(200)->json_has('/users');

$t->get_ok(
  $url . "rest/group/$group_id" => {'X-Bugzilla-API-Key' => $unprivileged_api_key})
  ->status_is(200)->json_is('/groups/0/name', 'secret-group');

# Clean up: remove the unprivileged user from can_see_groups again so that
# later tests (e.g. rest_user_get.t) still see it as belonging to no groups.
$t->put_ok($url
    . "rest/user/$unprivileged_login" => {'X-Bugzilla-API-Key' => $admin_api_key}
    => json => {groups => {remove => ['can_see_groups']}})->status_is(200)
  ->json_has('/users');

# A user who can bless one group, but is not in can_see_groups, asking for a
# different group: the blessability filter must leave it out rather than blow
# up. The legacy code mapped can_bless($group_object) over the list, which
# always returned 0, and _group_to_hash then called ->id on that 0.

my $bless_group = {
  name        => 'bless-only-group',
  description => 'Blessable, but not visible',
  is_active   => true
};
$t->post_ok($url
    . 'rest/group' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    $bless_group)->status_is(201)->json_has('/id');

my $bless_group_id = $t->tx->res->json->{id};

# HACK: bless privileges cannot be granted over the API.
Bugzilla->dbh->do(
  'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
     SELECT userid, ?, 1, ? FROM profiles WHERE login_name = ?',
  undef, $bless_group_id, GRANT_DIRECT, $unprivileged_login
);

$t->get_ok($url
    . "rest/group/$group_id" => {'X-Bugzilla-API-Key' => $unprivileged_api_key})
  ->status_is(200)->json_is('/groups' => []);

# Clean up: leave this user belonging to nothing, as later tests expect.
Bugzilla->dbh->do(
  'DELETE FROM user_group_map
    WHERE group_id = ? AND isbless = 1
      AND user_id = (SELECT userid FROM profiles WHERE login_name = ?)',
  undef, $bless_group_id, $unprivileged_login
);

done_testing();
