#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The @mention autocomplete (extensions/Needinfo/web/js/mention-autocomplete.js)
# asks GET /rest/user/suggest for "@<typed text>". Mentions resolve by nickname
# only, so that query must return enabled accounts whose nickname starts with
# the text, and never accounts that merely have a matching login or real name.

use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}         = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE}     = 1;
  $ENV{BUGZILLA_ALLOW_INSECURE_HTTP} = 1;
}

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Bugzilla::Constants  qw(GRANT_DIRECT);
use Bugzilla::Test::Util qw(create_bug create_group create_user issue_api_key);

use Test::More;
use Test::Mojo;

# The shared database isn't reset between runs, so every fixture is unique.
my $prefix = 'mnsg' . $$ . time;

my $requester = create_user("$prefix-requester\@example.com",
  '*', realname => "Mention Requester [:${prefix}self]");
my $nicked = create_user("$prefix-nicked\@example.com", '*',
  realname => "Mention Nicked [:${prefix}nick]");
my $login_only = create_user("${prefix}nick-login\@example.com",
  '*', realname => "${prefix}nick Login Only");
my $disabled = create_user(
  "$prefix-disabled\@example.com", '*',
  realname     => "Mention Disabled [:${prefix}nickoff]",
  disabledtext => 'Account closed.'
);

is($nicked->nick,           "${prefix}nick", 'nicked account has a nickname');
is($login_only->{nickname}, undef, 'login-only account has no nickname');
ok(!$disabled->is_enabled, 'disabled account is disabled');

# With a bug_id the autocomplete only offers accounts that can see the bug, as
# _mentioned_users drops the others on save. The requester and $insider are in
# the group restricting $secure_bug, $nicked isn't, and nobody is in the group
# restricting $hidden_bug. Group membership is memcached per user, so it is
# granted before the requester's first API call.
my $dbh = Bugzilla->dbh;
Bugzilla->set_user(Bugzilla::User->super_user);

my $insider = create_user("$prefix-insider\@example.com",
  '*', realname => "Mention Insider [:${prefix}nzinside]");

sub new_bug {
  my ($desc) = @_;
  return create_bug(
    short_desc  => "Mention suggest $prefix $desc",
    comment     => 'Bug for the @mention suggest tests',
    bug_type    => 'defect',
    assigned_to => 'nobody@mozilla.org',
  );
}

sub restricted_bug {
  my ($group, @members) = @_;
  $dbh->do(
    'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
     VALUES (?, ?, 0, ?)', undef, $_->id, $group->id, GRANT_DIRECT
  ) foreach @members;
  my $bug = new_bug('restricted to ' . $group->name);
  $dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
    undef, $bug->id, $group->id);
  return $bug;
}

my $public_bug = new_bug('public');
my $secure_bug = restricted_bug(create_group("$prefix-secure", isbuggroup => 1),
  $requester, $insider);
my $hidden_bug
  = restricted_bug(create_group("$prefix-hidden", isbuggroup => 1));

my $api_key = issue_api_key($requester->login)->api_key;
my $headers = {'X-Bugzilla-API-Key' => $api_key};
my $t       = Test::Mojo->new('Bugzilla::App');

sub suggested_logins {
  my ($match, %form) = @_;
  $t->get_ok('/rest/user/suggest' => $headers => form =>
      {match => $match, include_fields => 'name,real_name,nick,gravatar', %form})
    ->status_is(200);
  return [sort map { $_->{name} } @{$t->tx->res->json->{users} || []}];
}

is_deeply(suggested_logins("\@${prefix}ni"),
  [$nicked->login],
  '@-prefixed match returns only enabled accounts with a matching nickname');
is($t->tx->res->json->{users}[0]{nick},
  "${prefix}nick", 'the nickname to insert is returned');

is_deeply(
  suggested_logins("${prefix}ni"),
  [sort $nicked->login, $login_only->login],
  'without @ the login-only account matches too, which the autocomplete avoids'
);

is_deeply(suggested_logins("\@${prefix}self"),
  [$requester->login], 'the requester is not filtered out server-side');

is_deeply(suggested_logins("\@${prefix}zz"), [], 'no match returns no users');

$t->get_ok('/rest/user/suggest' => form => {match => "\@${prefix}ni"})
  ->status_isnt(200, 'logged-out users get no suggestions');

# "@<prefix>n" matches $nicked and $insider ($disabled is never returned).
is_deeply(
  suggested_logins("\@${prefix}n", bug_id => $public_bug->id),
  [sort $nicked->login, $insider->login],
  'a public bug keeps every matching account'
);

is_deeply(suggested_logins("\@${prefix}n", bug_id => $secure_bug->id),
  [$insider->login], 'a restricted bug leaves out accounts that cannot see it');

$t->get_ok('/rest/user/suggest' => $headers => form =>
    {match => "\@${prefix}n", bug_id => $hidden_bug->id})
  ->status_isnt(200,
  'a bug the requester cannot see fails rather than revealing who can see it');

done_testing;
