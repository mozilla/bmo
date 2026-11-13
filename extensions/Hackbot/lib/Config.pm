# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot::Config;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Config::Common;

our $sortkey = 1310;

sub get_param_list {
  return (
    {name => 'hackbot_enabled',      type => 'b', default => 0},
    {name => 'hackbot_runs_enabled', type => 'b', default => 0},
    {
      name    => 'hackbot_api_url',
      type    => 't',
      default => '',
      checker => \&check_urlbase
    },
    {name => 'hackbot_api_key', type => 'p', default => ''},
    {
      name    => 'hackbot_ui_url',
      type    => 't',
      default => 'https://hackbot.moz.tools/',
      checker => \&check_urlbase
    },
  );
}

1;
