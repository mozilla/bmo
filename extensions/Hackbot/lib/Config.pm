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
use Bugzilla::User;

our $sortkey = 1310;

sub get_param_list {
  my ($class) = @_;

  return ({
    name    => 'hackbot_user',
    type    => 't',
    default => '',
    checker => \&check_hackbot_user,
  });
}

# Empty is valid: it turns the extension off.
sub check_hackbot_user {
  my ($login) = @_;
  return '' if $login eq '' || Bugzilla::User::login_to_id($login);
  return "There is no user named '$login'.";
}

1;
