# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Controller::MFA::Duo;

use 5.10.1;
use Mojo::Base 'Mojolicious::Controller';

use Bugzilla::Constants;
use Bugzilla::DuoClient;
use Bugzilla::MFA;
use Bugzilla::Token qw(set_token_extra_data);

use Mojo::URL;

use constant ERR_INVALID_STATE =>
  'Invalid state value returned from Duo Security';
use constant ERR_INVALID_AUTH_CODE =>
  'Invalid auth code returned from Duo Security';
use constant ERR_INVALID_MFA_COOKIE =>
  'Invalid MFA cookie returned by client browser';
use constant ERR_INVALID_MFA_CODE => 'Invalid Duo Security MFA Code';

sub setup_routes {
  my ($class, $r) = @_;
  $r->any('/mfa/duo/callback')->to('MFA::Duo#callback')->name('duo_callback');
}

sub callback {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO);

  # Get state to verify consistency
  my $state = $self->param('state');

  # Get authorization code to trade for 2FA
  my $duo_code = $self->param('duo_code');

  # Also grab the mfa cookie to compare with the state from Duo
  my $mfa_cookie = $self->cookie('mfa_verification_token');

  # Sanity checks of required values
  $state
    || return $self->code_error('duo_client_error',
    {reason => ERR_INVALID_STATE});
  $duo_code
    || return $self->code_error('duo_client_error',
    {reason => ERR_INVALID_AUTH_CODE});
  $mfa_cookie
    || return $self->code_error('duo_client_error',
    {reason => ERR_INVALID_MFA_COOKIE});
  ($mfa_cookie eq $state)
    || return $self->code_error('duo_client_error',
    {reason => ERR_INVALID_MFA_COOKIE});

  # Match the token with the correct user
  my ($user_id) = Bugzilla::Token::GetTokenData($mfa_cookie);
  my $user = Bugzilla::User->check({id => $user_id, cache => 1});

  # Retrieve the event data from the mfa token
  my $provider = Bugzilla::MFA->new_from($user, 'Duo');
  # provider_callback skips the duo_verified gate: we are the request that is
  # about to establish it.
  my $event = $provider->verify_token($mfa_cookie,
    {no_redirect => 1, no_delete => 1, provider_callback => 1});
  if (!$event) {
    return $self->code_error('duo_client_error',
      {reason => ERR_INVALID_MFA_COOKIE});
  }

 # Obtain username from properities as it may be different than the BMO user name.
  my $username = $provider->property_get('user');

  my $params = Bugzilla->params;
  my $duo    = Bugzilla::DuoClient->new(
    uri           => $params->{duo_uri},
    client_id     => $params->{duo_client_id},
    client_secret => $params->{duo_client_secret},
  );

  # Using the code returned from Duo, we then verify it by posting data to Duo
  if (!$duo->exchange_authorization_code_for_2fa_result($duo_code, $username)) {
    return $self->user_error('duo_user_error', {reason => ERR_INVALID_MFA_CODE});
  }

  # If we got this far, we have successfully authenticated with Duo
  # MFA code later on will look for the duo_verified flag and will fail
  # if not present
  $event->{duo_verified} = 1;
  set_token_extra_data($mfa_cookie, $event);

  my $redirect_uri = Mojo::URL->new(Bugzilla->localconfig->urlbase);
  $redirect_uri->path($event->{postback}->{action});
  $redirect_uri->query->append(%{$event->{postback}->{fields}});

  # Redirect back to original place the user was when MFA
  # verfication was invoked
  $self->redirect_to($redirect_uri);
}

1;
