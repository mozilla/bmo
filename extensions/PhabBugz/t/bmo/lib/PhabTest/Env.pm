# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Per-file setup and teardown for the PhabBugz t/bmo tests.
#
# The t/bmo tests run against the shared MySQL database that `test_bmo`
# seeds once per container, so each file must leave it as it found it:
#
#   * fixtures get unique names (unique()),
#   * the phabbugz cursor rows (feed_last_id, user_last_id) are restored,
#   * bug groups created by the test are deactivated so later group syncs
#     do not see them,
#   * users created with bmo_user() are re-enabled if the test disabled them,
#   * anything else is cleaned up by on_teardown() callbacks,
#   * PhabBugz params are only ever set in memory (PhabTest::Conduit).
#
# Teardown runs from finish(), or from an END block if the test file dies
# first. END blocks run before global destruction, so the database handle
# is still usable; DESTROY is only a last resort.
#
# Usage:
#
#   my $env  = PhabTest::Env->new;     # also creates the fake Conduit
#   my $c    = $env->conduit;
#   my $user = $env->bmo_user('author');
#   my $phab = $env->link_user($user); # Phabricator user for a BMO user
#   ...
#   $env->finish;                      # verify Conduit usage, restore DB
#   done_testing;

package PhabTest::Env;

use 5.10.1;
use strict;
use warnings;

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Config qw(SetParam);
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::Test::Util qw(create_bug create_group create_user);
use Bugzilla::Extension::PhabBugz::Constants;

use PhabTest::Conduit;
use PhabTest::Fixtures qw(phid_for_bmo_user user_obj);
use Scalar::Util qw(refaddr weaken);
use Test::More ();
use Try::Tiny;

my $UNIQUE = 0;

# Envs that have not been torn down yet, for the END block.
my %LIVE;

sub new {
  my ($class) = @_;

  my $self = bless {
    groups   => [],
    linked   => [],
    users    => [],
    cleanups => [],
    finished => 0,
  }, $class;
  weaken($LIVE{refaddr $self} = $self);
  $self->{conduit} = PhabTest::Conduit->new;
  $self->_set_modes;

  my $dbh = Bugzilla->dbh;
  $self->{saved_cursors} = $dbh->selectall_arrayref(
    q{SELECT name, value FROM phabbugz
       WHERE name IN ('feed_last_id', 'user_last_id')}
  );

  $self->{admin} = Bugzilla::User->check({id => 1});
  Bugzilla->set_user($self->{admin});

  $self->{phab_bot} = create_user(PHAB_AUTOMATION_USER, '*',
    realname => 'Phabricator Automation');
  $self->{lando}
    = create_user(LANDO_AUTOMATION_USER, '*', realname => 'Lando Automation');

  # The automation users get linked Phabricator accounts by default, as the
  # feed daemon looks them up on every run.
  $self->{phab_bot_phab}
    = $self->link_user($self->{phab_bot}, username => 'phab-bot');
  $self->{lando_phab} = $self->link_user($self->{lando}, username => 'lobot');

  return $self;
}

sub conduit {
  my ($self) = @_;
  return $self->{conduit};
}

sub admin {
  my ($self) = @_;
  return $self->{admin};
}

sub phab_bot {
  my ($self) = @_;
  return $self->{phab_bot};
}

sub phab_bot_phab {
  my ($self) = @_;
  return $self->{phab_bot_phab};
}

sub lando_phab {
  my ($self) = @_;
  return $self->{lando_phab};
}

sub _set_modes {
  Bugzilla->usage_mode(USAGE_MODE_TEST);
  Bugzilla->error_mode(ERROR_MODE_DIE);
}

# A name no other test file or earlier run has used.
sub unique {
  my ($self, $suffix) = @_;
  return sprintf('phabtest-%x-%d-%d-%s', time, $$, ++$UNIQUE, $suffix // 'x');
}

sub bmo_user {
  my ($self, $suffix, %extra) = @_;
  my $login = $self->unique($suffix) . '@phabtest.example.com';
  my $user  = create_user($login, '*', realname => "PhabTest $suffix", %extra);
  push @{$self->{users}}, $user->id;
  return $user;
}

# Register a Phabricator user linked to $bmo_user in the fake Conduit and
# drop any memcached BMO id -> PHID mapping left from an earlier test.
sub link_user {
  my ($self, $bmo_user, %args) = @_;
  Bugzilla->memcached->clear({key => 'phab_user_bugzilla_id_' . $bmo_user->id});
  push @{$self->{linked}}, $bmo_user->id;
  my ($local_part) = split /@/, $bmo_user->login;
  return $self->{conduit}->add_user(user_obj(
    id       => $args{id} // 100_000 + $bmo_user->id,
    phid     => phid_for_bmo_user($bmo_user->id),
    username => $args{username} // $local_part,
    realname => $args{realname} // $bmo_user->name,
    bmo_id   => $bmo_user->id,
  ));
}

# An active bug group, deactivated again by teardown().
sub bug_group {
  my ($self, $suffix) = @_;
  return $self->group($suffix, isbuggroup => 1);
}

# Any group (pass `isbuggroup => 0` for a system group), deactivated again
# by teardown().
sub group {
  my ($self, $suffix, %args) = @_;
  my $group = create_group(
    $self->unique($suffix),
    isactive      => 1,
    owner_user_id => $self->{admin}->login,
    %args,
  );
  push @{$self->{groups}}, $group;
  return $group;
}

# Register cleanup for rows the Env does not know about. Callbacks run in
# teardown(), newest first, even if the test died part way through.
sub on_teardown {
  my ($self, $code) = @_;
  push @{$self->{cleanups}}, $code;
  return $self;
}

sub add_to_group {
  my ($self, $user, $group) = @_;
  Bugzilla->dbh->do(
    'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type)
     VALUES (?, ?, 0, ?)', undef, $user->id, $group->id, GRANT_DIRECT
  );
  return $self;
}

sub remove_from_group {
  my ($self, $user, $group) = @_;
  Bugzilla->dbh->do(
    'DELETE FROM user_group_map WHERE user_id = ? AND group_id = ? AND isbless = 0',
    undef, $user->id, $group->id
  );
  return $self;
}

# A bug filed by the admin, in Firefox :: General unless `product` and
# `component` are given. Pass `groups => [$group, ...]` to make it private,
# `cc => [$user, ...]` and `assigned_to => $user`.
sub bug {
  my ($self, %args) = @_;
  my $restore = Bugzilla->set_user($self->{admin}, scope_guard => 1);
  my $product = $args{product} // 'Firefox';
  my $bug     = create_bug(
    short_desc => $args{summary} // $self->unique('bug'),
    product    => $product,
    component  => $args{component} // 'General',
    bug_type   => 'defect',
    version    => $product eq 'Firefox'
    ? 'Trunk'
    : Bugzilla::Product->new({name => $product})->versions->[0]->name,
    cc          => [map { $_->login } @{$args{cc} // []}],
    comment     => 'PhabBugz test bug',
    assigned_to =>
      ($args{assigned_to} ? $args{assigned_to}->login : 'nobody@mozilla.org'),
  );

  # Add groups straight to bug_group_map: Firefox's group controls do not
  # allow arbitrary test groups through Bug->create.
  if (my $groups = $args{groups}) {
    my $dbh = Bugzilla->dbh;
    $dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
      undef, $bug->id, $_->id)
      foreach @$groups;
  }

  return Bugzilla::Bug->new($bug->id);
}

# A saved feed cursor is always a story the daemon already processed, so
# tell the fake Conduit it exists.
sub save_cursor {
  my ($self, $type, $value) = @_;
  Bugzilla->dbh->do('REPLACE INTO phabbugz (name, value) VALUES (?, ?)',
    undef, "${type}_last_id", $value);
  $self->{conduit}->add_seen_story($value) if $type eq 'feed' && $value;
}

sub cursor {
  my ($self, $type) = @_;
  my ($value)
    = Bugzilla->dbh->selectrow_array('SELECT value FROM phabbugz WHERE name = ?',
    undef, "${type}_last_id");
  return $value;
}

# Start a new "request": clear the request cache (cached bugs, users and
# params) and put back the test user, error mode and PhabBugz params.
sub fresh_request {
  my ($self, $user) = @_;
  Bugzilla->clear_request_cache;
  _set_modes();
  Bugzilla->set_user($user // $self->{admin});
  $self->{conduit}->apply_params;
  return $self;
}

# Run one feed daemon sync ($code, e.g. sub { $feed->feed_query }) as a
# fresh request with no calls recorded yet. Returns the exception, if any.
sub run_sync {
  my ($self, $code) = @_;
  $self->fresh_request;
  $self->{conduit}->reset_calls;
  my $error;
  try { $code->() } catch { $error = $_ };
  return $error;
}

# Check that the sync in $code makes no Conduit calls with
# phabricator_enabled off. The next fresh_request turns it back on.
sub sync_disabled_ok {
  my ($self, $code) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  SetParam('phabricator_enabled', 0);
  $self->{conduit}->reset_calls;
  $code->();
  Test::More::is($self->{conduit}->call_count,
    0, 'no Conduit calls with phabricator_enabled off');
}

sub finish {
  my ($self) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  $self->{conduit}->verify;
  $self->teardown;
}

sub teardown {
  my ($self) = @_;
  return if $self->{finished}++;
  delete $LIVE{refaddr $self};

  my $dbh = Bugzilla->dbh;
  $dbh->bz_rollback_transaction() if $dbh->bz_in_transaction;

  # Each step runs on its own so one failure does not skip the rest.
  _try_step($_) foreach reverse @{$self->{cleanups}};

  _try_step(sub {
    $dbh->do(
      q{DELETE FROM phabbugz WHERE name IN ('feed_last_id', 'user_last_id')});
    $dbh->do('INSERT INTO phabbugz (name, value) VALUES (?, ?)', undef, @$_)
      foreach @{$self->{saved_cursors}};
  });

  foreach my $group (@{$self->{groups}}) {
    _try_step(sub {
      my $fresh = Bugzilla::Group->new($group->id) or return;
      $fresh->set_is_active(0);
      $fresh->update;
    });
  }

  # Plain SQL rather than User->update, so the PhabBugz hook does not send
  # a user.edit to the fake Conduit after verify() has run.
  if (my @users = @{$self->{users}}) {
    _try_step(sub {
      $dbh->do(
        'UPDATE profiles SET disabledtext = ?, is_enabled = 1 WHERE userid IN ('
          . join(',', ('?') x @users) . ')',
        undef, '', @users
      );
      Bugzilla->memcached->clear({table => 'profiles', id => $_}) foreach @users;
    });
  }

  _try_step(sub {
    Bugzilla->memcached->clear({key => "phab_user_bugzilla_id_$_"})
      foreach @{$self->{linked}};
  });
}

sub _try_step {
  my ($code) = @_;
  local $@ = undef;
  eval { $code->(); 1 } or warn "PhabTest::Env teardown step failed: $@";
}

# Runs before global destruction, while Bugzilla->dbh still works, for test
# files that die before calling finish().
END {
  local $? = $?;
  foreach my $env (grep {defined} values %LIVE) {
    local $@ = undef;
    eval { $env->teardown; 1 } or warn "PhabTest::Env teardown failed: $@";
  }
}

sub DESTROY {
  my ($self) = @_;
  return if $self->{finished};
  local $@ = undef;
  eval { $self->teardown; 1 } or warn "PhabTest::Env teardown failed: $@";
}

1;
