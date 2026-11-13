# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot::API::V1::Runs;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Extension::Hackbot::BugRuns;
use Bugzilla::Extension::Hackbot::Constants;

sub setup_routes {
  my ($class, $r) = @_;
  $r->get('/hackbot/bug_runs/:bug_id')->to('Hackbot::API::V1::Runs#bug_runs');
}

sub bug_runs {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login(LOGIN_REQUIRED);
  $user->id || return $self->user_error('login_required');

  # Kill switch: when disabled, return nothing rather than calling Hackbot.
  return $self->render(json => {runs => []})
    unless Bugzilla::Extension::Hackbot::BugRuns->enabled;

  $user->in_group(HACKBOT_GROUP)
    || return $self->user_error('auth_failure',
    {group => HACKBOT_GROUP, action => 'access', object => 'bugs'});

  my $bug_id = $self->param('bug_id');
  return $self->user_error('invalid_parameter',
    {name => 'bug_id', err => 'must be a bug id'})
    unless $bug_id && $bug_id =~ /^\d+$/;

  # Throws unless the user can see the bug, so runs on a security bug are
  # never shown to someone who can't see the bug itself.
  my $bug = Bugzilla::Bug->check({id => $bug_id, cache => 1});

  my $result = Bugzilla::Extension::Hackbot::BugRuns->for_bug($bug->id);

  # The details are logged server-side; the table only needs to know it failed.
  return $self->render(
    status => 502,
    json   => {error => 1, message => 'Hackbot is unavailable'}
  ) unless $result->{ok};

  return $self->render(json => {runs => $result->{runs}});
}

1;
