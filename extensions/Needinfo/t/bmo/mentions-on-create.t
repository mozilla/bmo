#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 2087012: @mentions in the description of a new bug needinfo the
# mentioned users, like mentions in a later comment do. Bugs are filed through
# the real post_bug.cgi (and POST /rest/bug), in-process with Test::Mojo, so
# the usage mode, the request and the create-then-update sequence are the ones
# production uses. The rules themselves are covered without a DB in
# extensions/Needinfo/t/mentions.t.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

# Before anything pulls in Bugzilla::Error: CGI::Compile installs
# CORE::GLOBAL::exit, which the legacy CGI wrapper relies on to turn a
# script's exit into a catchable exception (see t/buglist-series-idor.t).
use CGI::Compile;

use Bugzilla;
BEGIN { Bugzilla->extensions }
use Bugzilla::App    ();
use Bugzilla::Config qw(SetParam write_params);
use Bugzilla::Constants;
use Bugzilla::FlagType;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::Token qw(issue_session_token);
use Bugzilla::User;
use Bugzilla::User::Setting qw(clear_settings_cache);
use Bugzilla::Util          qw(generate_random_password);
use Bugzilla::Test::Util    qw(create_user issue_api_key);

use Mojo::Cookie::Response;
use Test::More;
use Test::Mojo;

my $dbh = Bugzilla->dbh;

my ($needinfo) = @{Bugzilla::FlagType::match({name => 'needinfo'})};
plan skip_all => 'needinfo flag type not installed' unless $needinfo;

# The app reads params from the database (through memcached) on every
# request, so set them there, and put them back afterwards.
my $mentions_enabled = Bugzilla->params->{needinfo_mentions_enabled} // 0;

sub set_mentions_enabled {
  SetParam('needinfo_mentions_enabled', $_[0]);
  write_params();
}
set_mentions_enabled(1);
END { set_mentions_enabled($mentions_enabled) if defined $mentions_enabled }

my $admin = Bugzilla::User->check({id => 1});
Bugzilla->set_user($admin);

# The nickname comes from the [:nick] in the real name. Reused on a rerun.
sub mention_user {
  my ($nick) = @_;
  my $user = create_user("$nick\@needinfo-mentions.test",
    '*', realname => "Needinfo Mention [:$nick]");
  is($user->nick, $nick, "fixture $nick has the nickname");
  return $user;
}

sub block_needinfo {
  my ($user, $value) = @_;
  $user->settings->{block_needinfo}->set($value);
  clear_settings_cache($user->id);
}

my $alice   = mention_user('nimention-alice');
my $bob     = mention_user('nimention-bob');
my $blocked = mention_user('nimention-blocked');
my $hackbot = mention_user('nimention-hackbot');
block_needinfo($alice,   'off');
block_needinfo($bob,     'off');
block_needinfo($blocked, 'on');
block_needinfo($hackbot, 'editbugs');

# A group restricting bugs that none of the mentioned users are in, for the
# last test. Set up before the app runs any request: set_groups audits the
# change with remote_ip(), which wants a controller once a request has run.
my $product   = Bugzilla::Product->check('Firefox');
my $sec_group = Bugzilla::Group->create({
  name        => "needinfo-mention-sec-$$",
  description => 'Temp security group for Bug 2087012 test',
  isbuggroup  => 1,
  silently    => 1,
});
$dbh->do(
  'INSERT IGNORE INTO group_control_map
     (group_id, product_id, entry, membercontrol, othercontrol, canedit)
   VALUES (?, ?, 0, 1, 0, 0)', undef, $sec_group->id, $product->id
);

# Re-read the admin so can_bless sees the new group (the admin group is
# granted bless on every group at creation).
$admin = Bugzilla::User->new({id => $admin->id});
Bugzilla->set_user($admin);
$admin->set_groups({add => [$sec_group->name]});
$admin->update();

# One Test::Mojo for the whole file: building the app twice makes CGI::Compile
# die with "Tried to load admin.cgi more than once".
my $t  = Test::Mojo->new('Bugzilla::App');
my $ua = $t->ua;

# Log in as the web UI does: a logincookies row and the matching cookies.
my $cookie = generate_random_password(16);
$dbh->do(
  'INSERT INTO logincookies (cookie, userid, lastused) VALUES (?, ?, NOW())',
  undef, $cookie, $admin->id);
$ua->cookie_jar->add(
  map {
    Mojo::Cookie::Response->new(
      name   => $_->[0],
      value  => $_->[1],
      domain => $ua->server->url->host,
      path   => '/'
    )
  } ['Bugzilla_login', $admin->id],
  ['Bugzilla_logincookie', $cookie]
);

my %bug_fields = (
  product      => 'Firefox',
  component    => 'General',
  version      => 'Trunk',
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  short_desc   => 'Needinfo mentions on bug creation',
);

# File a bug through the enter_bug form. %args: comment, flags (requestee
# logins to needinfo explicitly on the form), groups. Returns the bug id.
sub file_bug {
  my (%args) = @_;
  my %form = (
    %bug_fields,
    comment => $args{comment},
    token   => scalar issue_session_token('create_bug', $admin),
  );
  if (my @requestees = @{$args{flags} || []}) {
    $form{'flag_type-' . $needinfo->id}      = '?';
    $form{'requestee_type-' . $needinfo->id} = join(', ', @requestees);
  }
  $form{groups} = $args{groups} if $args{groups};

  $t->post_ok('/post_bug.cgi' => form => \%form)
    ->status_is(302, 'post_bug.cgi files the bug');
  my ($id)
    = ($t->tx->res->headers->location // '') =~ /show_bug\.cgi(?:\?|%3F)id=(\d+)/;
  ok($id, '... and redirects to it') or diag $t->tx->res->body;
  return $id;
}

# Logins of the pending needinfo requestees on a bug, sorted, with repeats.
sub needinfo_from {
  my ($bug_id) = @_;
  return $dbh->selectcol_arrayref(
    'SELECT profiles.login_name FROM flags
       INNER JOIN profiles ON profiles.userid = flags.requestee_id
      WHERE flags.bug_id = ? AND flags.type_id = ? AND flags.status = ?
      ORDER BY profiles.login_name', undef, $bug_id, $needinfo->id, '?'
  );
}

sub cc_list {
  my ($bug_id) = @_;
  return $dbh->selectcol_arrayref(
    'SELECT profiles.login_name FROM cc
       INNER JOIN profiles ON profiles.userid = cc.who
      WHERE cc.bug_id = ? ORDER BY profiles.login_name', undef, $bug_id
  );
}

my $bug_id
  = file_bug(comment => "\@nimention-alice and \@nimention-bob, can you look?\n"
    . "> \@nimention-blocked in a quote is ignored");
is_deeply(
  needinfo_from($bug_id),
  [$alice->login, $bob->login],
  'mentions in the description needinfo the mentioned users'
);
is_deeply(cc_list($bug_id), [$alice->login, $bob->login], '... and CC them');

my ($creation_ts, $flag_when) = $dbh->selectrow_array(
  "SELECT bugs.creation_ts, bugs_activity.bug_when
     FROM bugs
          INNER JOIN bugs_activity ON bugs_activity.bug_id = bugs.bug_id
          INNER JOIN fielddefs ON fielddefs.id = bugs_activity.fieldid
    WHERE bugs.bug_id = ? AND fielddefs.name = 'flagtypes.name'
          AND bugs_activity.added LIKE 'needinfo?%' " . $dbh->sql_limit(1),
  undef, $bug_id
);
ok($flag_when, 'the needinfo requests are in the bug activity');
is($flag_when, $creation_ts, '... at the creation time, like form flags');

$bug_id = file_bug(comment => '@nimention-alice please look',
  flags => [$alice->login]);
is_deeply(needinfo_from($bug_id), [$alice->login],
  'a user needinfod on the form and mentioned gets one request');

$bug_id = file_bug(comment => '@nimention-blocked @nimention-alice');
is_deeply(needinfo_from($bug_id), [$alice->login],
  'a user blocking needinfo is not needinfod, and the bug is still filed');
is_deeply(cc_list($bug_id), [$alice->login, $blocked->login], '... but is CCd');

$bug_id = file_bug(comment => '@nimention-hackbot please triage');
is_deeply(needinfo_from($bug_id), [$hackbot->login],
  'an account restricted to editbugs requesters is needinfod by editbugs');

$bug_id = file_bug(comment => '@' . $admin->nick . ' note to self');
is_deeply(needinfo_from($bug_id), [], 'the reporter is not needinfod');

# Cloning prefills the description with the original one under a header (see
# enter_bug.cgi); only the mentions the reporter adds count.
my $original_text = "\@nimention-alice can you look?\nSteps to reproduce";
my $original_id   = file_bug(comment => $original_text);
$bug_id
  = file_bug(comment => "+++ This bug was initially created as a clone of Bug "
    . "#$original_id +++\n\n\n\@nimention-bob this is the follow-up\n\n"
    . $original_text);
is_deeply(needinfo_from($bug_id), [$bob->login],
  'clone: mentions copied from the original description are ignored');
is_deeply(cc_list($bug_id), [$bob->login], '... and not CCd');

set_mentions_enabled(0);
$bug_id = file_bug(comment => '@nimention-alice');
is_deeply(needinfo_from($bug_id), [],
  'nothing when needinfo_mentions_enabled is off');
is_deeply(cc_list($bug_id), [], '... and no CC');
set_mentions_enabled(1);

# Like comments, descriptions filed through the API don't trigger mentions,
# even when the bug is updated after creation to set flags.
my $api_key = issue_api_key($admin->login)->api_key;
$t->post_ok(
  '/rest/bug' => {'X-BUGZILLA-API-KEY' => $api_key} => json => {
    %bug_fields,
    description => '@nimention-alice',
    flags       => [{name => 'needinfo', status => '?', requestee => $bob->login}],
  }
)->status_is(200, 'POST /rest/bug files the bug');
$bug_id = $t->tx->res->json('/id');
is_deeply(needinfo_from($bug_id), [$bob->login],
  'API: only the explicit needinfo, no mentions');


# A mention never grants access to a restricted bug.
$bug_id = file_bug(comment => '@nimention-alice', groups => [$sec_group->name]);
is_deeply(
  $dbh->selectcol_arrayref(
    'SELECT group_id FROM bug_group_map WHERE bug_id = ?',
    undef, $bug_id
  ),
  [$sec_group->id],
  'the bug is restricted'
);
is_deeply(needinfo_from($bug_id), [],
  'restricted bug: no needinfo for a non-member');
is_deeply(cc_list($bug_id), [], '... and no CC');

done_testing;
