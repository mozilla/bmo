# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::MFA::Duo;

use 5.10.1;
use strict;
use warnings;

use base 'Bugzilla::MFA';

use Bugzilla::DuoClient;
use Bugzilla::Error;

sub can_verify_inline {
  return 0;
}

# Duo verification happens in a separate request handled by
# Bugzilla::App::Controller::MFA::Duo, which sets duo_verified on the event
# once the authorization code has been exchanged.  Without it the mfa token
# only proves the prompt was issued, not that the user passed Duo.
sub verify_event {
  my ($self, $event) = @_;
  return if $event->{duo_verified};
  ThrowUserError('duo_user_error', {reason => 'Invalid Duo Security MFA Code'});
}

# Duo users have no way to enter a recovery code -- there is no Duo
# verification form, prompt() redirects straight to Duo.  Recovery is handled
# by Duo itself (bypass codes, self-service device management).
sub generate_recovery_codes {
  my ($self) = @_;
  ThrowUserError('duo_user_error',
    {reason => 'Recovery codes are not available when using Duo Security.'});
}

sub enroll {
  my ($self, $params) = @_;

  # Do not allow Duo enrollment unless required or user is a Mozilla employee
  my $user = Bugzilla->user;
  unless ($user->in_duo_required_group
    || $user->in_group('mozilla-employee-confidential'))
  {
    ThrowUserError('duo_user_error',
      {reason => 'You are not permitted to enroll Duo Security for this account.'});
  }

  $self->property_set('user', $params->{username});
}

sub prompt {
  my ($self, $vars, $token) = @_;
  my $cgi    = Bugzilla->cgi;
  my $params = Bugzilla->params;

  my $duo = Bugzilla::DuoClient->new(
    uri           => $params->{duo_uri},
    client_id     => $params->{duo_client_id},
    client_secret => $params->{duo_client_secret},
  );

  # Make sure Duo Security service is available
  $duo->health_check();

  # Set cookie with token to verify form submitted
  # from Bugzilla and not a different domain.
  $cgi->send_cookie(
    -name     => 'mfa_verification_token',
    -value    => $token,
    -httponly => 1,
  );

  my $username     = $self->property_get('user');
  my $redirect_uri = $duo->create_auth_url($username, $token);

  print $cgi->redirect($redirect_uri);
}

1;
