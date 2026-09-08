#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Verifies that PUT /rest/group/<name_or_id> enforces the same protected group
# rules as editgroups.cgi: holding creategroups is not enough to modify the
# admin group, or the insider group unless the caller is an insider. Editing
# the admin group would otherwise allow privilege escalation through
# user_regexp, which grants membership automatically.

use strict;
use warnings;
use 5.10.1;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;

use QA::Util qw(get_config);

use Test::Mojo;
use Test::More;

my $config               = get_config();
my $admin_api_key        = $config->{admin_user_api_key};
my $unprivileged_api_key = $config->{unprivileged_user_api_key};
my $caller_api_key       = $config->{creategroups_user_api_key};
my $group_name           = $config->{protected_group_name};
my $url                  = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Read a group back as the admin. The request goes through the web server, so
# the object caches in this process know nothing about it.
sub group_record {
  my ($name) = @_;
  $t->get_ok(
    $url . "rest/group?names=$name" => {'X-Bugzilla-API-Key' => $admin_api_key})
    ->status_is(200);
  return $t->tx->res->json->{groups}[0];
}

my $admin_group = group_record('admin');
my $admin_id    = $admin_group->{id};
my $admin_desc  = $admin_group->{description};

# Reset the description as the admin, so that the update below is a change
# even on a re-run of this test.
$t->put_ok($url
    . "rest/group/$group_name" => {'X-Bugzilla-API-Key' => $admin_api_key} =>
    json => {description => 'REST protected group test'})->status_is(200);

# The rejected requests below deliberately do not touch user_regexp. Setting it
# on the admin group grants membership to every account matching the new
# expression, so should this guard ever regress, such a payload would leave the
# database with every user an admin and cascade into every later test in the
# rest_*.t run.

#
# 1. A caller without creategroups cannot update any group. This is the
#    negative control: REST authentication itself is working.
#
$t->put_ok($url
    . "rest/group/$group_name" =>
    {'X-Bugzilla-API-Key' => $unprivileged_api_key} => json =>
    {description => 'Should Not Happen'})
  ->status_is(401)
  ->json_is('/code', 304, 'Caller without creategroups is rejected');

#
# 2. A caller with creategroups can still update an ordinary group.
#
$t->put_ok($url
    . "rest/group/$group_name" => {'X-Bugzilla-API-Key' => $caller_api_key} =>
    json => {description => 'REST protected group test updated'})
  ->status_is(200)
  ->json_is(
  '/groups/0/changes/description/added',
  'REST protected group test updated',
  'creategroups can update an unprotected group'
  );

#
# 3. The same caller cannot update the admin group, by name...
#
$t->put_ok($url
    . 'rest/group/admin' => {'X-Bugzilla-API-Key' => $caller_api_key} => json =>
    {description => 'Hijacked by creategroups'})
  ->status_is(401)
  ->json_is('/code', 304, 'creategroups cannot update the admin group by name');

#
# ...nor by id.
#
$t->put_ok($url
    . "rest/group/$admin_id" => {'X-Bugzilla-API-Key' => $caller_api_key} =>
    json                     => {description => 'Hijacked by creategroups'})
  ->status_is(401)
  ->json_is('/code', 304, 'creategroups cannot update the admin group by id');

# The admin group was left alone.
is(group_record('admin')->{description},
  $admin_desc, 'The admin group description was not modified');

#
# 4. Nor can it update the insider group.
#
my $insider_group = Bugzilla->params->{insidergroup};
my $insider_desc
  = $insider_group ? group_record($insider_group)->{description} : undef;

SKIP: {
  skip 'insidergroup is not set', 6 unless $insider_group;

  $t->put_ok($url
      . "rest/group/$insider_group" => {'X-Bugzilla-API-Key' => $caller_api_key} =>
      json                          => {description => 'Hijacked by creategroups'})
    ->status_is(401)
    ->json_is('/code', 304, 'creategroups alone cannot update the insider group');

  is(group_record($insider_group)->{description},
    $insider_desc, 'The insider group description was not modified');
}

#
# 5. Admins are unaffected. The description is set to its current value so
#    that no other test sees a modified admin group.
#
$t->put_ok($url
    . 'rest/group/admin' => {'X-Bugzilla-API-Key' => $admin_api_key} => json =>
    {description => $admin_desc})
  ->status_is(200)
  ->json_has('/groups', 'An admin can still update the admin group');

done_testing();
