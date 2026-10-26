# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::UserMFA;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Constants;
use Bugzilla::Token;
use Bugzilla::User;
use Bugzilla::WebService::Util qw(merge_request_params);

sub setup_routes {
  my ($class, $r) = @_;
  my $routes
    = $r->under('/' => sub { Bugzilla->usage_mode(USAGE_MODE_MOJO_REST); });

  $routes->get('/user/mfa/#provider/enroll')->to('V1::UserMFA#enroll');
  $routes->options('/user/mfa/#provider/enroll')
    ->to('V1::UserMFA#options', allow => 'GET');

  $routes->post('/user/mfa/verify_totp_code')->to('V1::UserMFA#verify_totp_code');
  $routes->options('/user/mfa/verify_totp_code')
    ->to('V1::UserMFA#options', allow => 'POST');
}

sub options {
  my ($self) = @_;

  my $allow = $self->stash('allow');
  $self->res->headers->header('Allow'                        => $allow);
  $self->res->headers->header('Access-Control-Allow-Methods' => $allow);

  return $self->rendered(200);
}

# Called by the MFA preferences page (js/account.js) to get the QR code and
# secret for a new TOTP enrollment. The provider is only set on the in-memory
# user, as in the legacy method: enrollment is saved when the user confirms
# it with a code from the preferences form.
sub enroll {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # set_mfa turns an unknown name into no provider at all.
  $user->set_mfa($self->param('provider'));
  my $provider = $user->mfa_provider // return $self->user_error('invalid_params',
    {type_error => 'Unknown MFA provider'});

  # Only TOTP has an enrollment API: the others return an empty list, which
  # would leave render() an odd number of arguments.
  return $self->render(json => scalar $provider->enroll_api());
}

# Pre-validates the user's TOTP code on the verification form (js/mfa_totp.js)
# before it is submitted. The user is still in the middle of logging in, so is
# identified by the mfa_token issued with the form, not by bugzilla.login.
# Like the legacy method, a bad or missing token is reported as
# {error: 1, message} with a 200 status, which the form's script displays.
sub verify_totp_code {
  my ($self) = @_;

  my ($params, $error) = merge_request_params($self);
  return $self->user_error($error) if $error;

  my ($user_id) = Bugzilla::Token::GetTokenData($params->{mfa_token});
  return $self->_verify_error('invalid verification token') if !$user_id;

  my $user = Bugzilla::User->new({id => $user_id});
  return $self->_verify_error('mfa not enabled') if !$user->mfa;

  # A wrong code throws mfa_bad_code, which the form displays as "Invalid
  # verification code." The legacy method wrapped this in a try whose catch
  # could not change the response: the error had already been raised.
  # Pass no_delete=1 in case the user is using a recovery code: it must not
  # be used up until the form itself is submitted.
  $user->mfa_provider->verify_check(
    {code => $params->{mfa_code}, no_delete => 1});

  return $self->render(json => {error => 0});
}

sub _verify_error {
  my ($self, $message) = @_;
  return $self->render(json => {error => 1, message => $message});
}

1;
