# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot;

use 5.10.1;
use strict;
use warnings;

use parent qw(Bugzilla::Extension);

use Bugzilla;
use Bugzilla::Extension::Hackbot::BugRuns;
use Bugzilla::Extension::Hackbot::Constants;

our $VERSION = '0.01';

sub config_add_panels {
  my ($self, $args) = @_;
  $args->{panel_modules}->{Hackbot} = 'Bugzilla::Extension::Hackbot::Config';
}

# Flag the bug page to include the (initially hidden) Hackbot runs module.
# Whether a bug has runs isn't known until the browser asks the API, so the
# module's JS reveals it only when there is something to show.
sub template_before_process {
  my ($self, $args) = @_;
  my $file = $args->{file};
  my $vars = $args->{vars};

  return unless $file =~ m{bug_modal/(?:header|edit)\.html\.tmpl$};
  return unless Bugzilla::Extension::Hackbot::BugRuns->enabled;
  return unless Bugzilla->user->in_group(HACKBOT_GROUP);

  my $bug = exists $vars->{bugs} ? $vars->{bugs}[0] : $vars->{bug};
  return unless $bug && $bug->id;

  $vars->{hackbot_runs} = 1;
}

__PACKAGE__->NAME;
