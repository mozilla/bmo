# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Plugin::Login;
use 5.10.1;
use Mojo::Base 'Mojolicious::Plugin';

use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Token;
use Bugzilla::User::APIKey;
use Bugzilla::Util qw(i_am_webservice with_writable_database);

use Mojo::Util qw(secure_compare);
use URI;

sub register {
  my ($self, $app, $conf) = @_;

  $app->helper(
    'bugzilla.login_redirect_if_required' => sub {
      my ($c, $type) = @_;

      if ($type == LOGIN_REQUIRED) {
        $c->redirect_to(Bugzilla->localconfig->basepath . 'login');
        return undef;
      }
      else {
        return Bugzilla->user;
      }
    }
  );

  $app->helper(
    'bugzilla.redirect_to_password_reset' => sub {
      my ($c, $user) = @_;

      # Drop any pending Mojo login continuation. Otherwise Bugzilla->login()
      # on the reset page consumes it and bounces the user straight back to
      # where they came from (e.g. /oauth/authorize) before they get a chance
      # to set a new password.
      delete $c->session->{override_login_target};
      delete $c->session->{cgi_params};

      # reset_password.cgi only honours prev_url when it carries a valid
      # signature, so sign it the same way Bugzilla->login() does.
      my $abs_url  = $c->req->url->to_abs;
      my $self_url = $abs_url->to_string;
      my $redir_url
        = URI->new(Bugzilla->localconfig->basepath . 'reset_password.cgi');
      $redir_url->query_form(
        prev_url     => $self_url,
        prev_url_sig => issue_hash_sig('prev_url:' . $user->id, $self_url),
      );

      $c->redirect_to($redir_url->as_string);
      return undef;
    }
  );

  # A credential minted while the account was usable must not outlive the
  # account being shut off. Bugzilla::Auth::login() enforces this for the
  # legacy stack (which is what produces account_disabled on rest.cgi and in
  # the web UI); every authentication path on the native Mojo stack has to
  # funnel through here so they all refuse the same accounts the same way.
  #
  # Returns the user when the account may be used, or undef when the caller
  # has already been redirected.
  $app->helper(
    'bugzilla.assert_account_usable' => sub {
      my ($c, $user) = @_;

      if (!$user->is_enabled) {
        ThrowUserError('account_disabled', {disabled_reason => $user->disabledtext});
      }

      # Likewise for an account confined to a password reset, mirroring
      # Bugzilla::login().
      if ($user->password_change_required) {

        # We cannot show the password reset UI for API calls, so treat those
        # as a disabled account. i_am_webservice() predates the native REST
        # stack and does not know about USAGE_MODE_MOJO_REST.
        if (i_am_webservice() || Bugzilla->usage_mode == USAGE_MODE_MOJO_REST) {
          ThrowUserError('account_disabled',
            {disabled_reason => $user->password_change_reason});
        }

        # Otherwise send them to the page that lets them fix it.
        return $c->bugzilla->redirect_to_password_reset($user);
      }

      return $user;
    }
  );

  $app->helper(
    'bugzilla.login' => sub {
      my ($c, $type) = @_;
      $type //= LOGIN_NORMAL;
      my $headers = $c->tx->req->headers;
      my $user_id = 0;

      return Bugzilla->user if Bugzilla->user->id;

      $type = LOGIN_REQUIRED
        if $c->param('GoAheadAndLogIn') || Bugzilla->params->{requirelogin};

      # Allow templates to know that we're in a page that always requires
      # login.
      if ($type == LOGIN_REQUIRED) {
        Bugzilla->request_cache->{page_requires_login} = 1;
      }

      # Try cookies first if we are using the web UI
      my $usage_mode = Bugzilla->usage_mode;
      if ( $usage_mode == USAGE_MODE_BROWSER
        || $usage_mode == USAGE_MODE_MOJO
        || $usage_mode == USAGE_MODE_MOJO_REST)
      {
        my $login_cookie  = $c->cookie("Bugzilla_logincookie");
        my $login_user_id = $c->cookie("Bugzilla_login");

        # For REST API requests, cookie authentication additionally requires a
        # valid Bugzilla_api_token which acts as a CSRF token. This mirrors the
        # legacy WebService flow in Bugzilla::Auth::Login::Cookie.
        if ($usage_mode == USAGE_MODE_MOJO_REST) {
          if (defined(my $api_token = $c->param('Bugzilla_api_token'))) {
            my ($token_user_id, undef, undef, $token_type)
              = Bugzilla::Token::GetTokenData($api_token);
            if ( !defined $token_type
              || $token_type ne 'api_token'
              || !$login_user_id
              || $login_user_id != $token_user_id)
            {
              Bugzilla->check_rate_limit('token_mismatch');
              ThrowUserError('auth_invalid_token', {token => $api_token});
            }
          }
          elsif ($login_cookie) {

            # REST requires an api-token when using cookie authentication;
            # fall back to a non-authenticated request.
            $login_cookie = '';
          }
        }

        if ($login_cookie && $login_user_id) {
          my $db_cookie
            = Bugzilla->dbh->selectrow_array(
            'SELECT cookie FROM logincookies WHERE cookie = ? AND userid = ?',
            undef, ($login_cookie, $login_user_id));

          if (defined $db_cookie && secure_compare($login_cookie, $db_cookie)) {
            $user_id = $login_user_id;

            # If we logged in successfully, then update the lastused
            # time on the login cookie
            with_writable_database {
              Bugzilla->dbh->do(
                q{ UPDATE logincookies SET lastused = NOW() WHERE cookie = ? },
                undef, $login_cookie);
            };
          }
        }
      }

      # For api requests, we check for the api key in the header
      if ($usage_mode == USAGE_MODE_REST || $usage_mode == USAGE_MODE_MOJO_REST) {
        if (my $api_key_text = $headers->header('x-bugzilla-api-key')) {
          if (my $api_key = Bugzilla::User::APIKey->new({name => $api_key_text})) {
            my $remote_ip = $c->tx->remote_address;
            if (
              (
                   $api_key->sticky
                && $api_key->last_used_ip
                && $api_key->last_used_ip ne $remote_ip
              )
              || $api_key->revoked
              )
            {
              Bugzilla->check_rate_limit('api_key_mismatch');
            }
            else {
              $api_key->update_last_used($remote_ip);
              $user_id = $api_key->user_id;
            }
          }
          else {
            Bugzilla->check_rate_limit('api_key_mismatch');
          }
        }

        # Also allow use of OAuth2 bearer tokens to access the API
        if ($headers->header('Authorization')) {
          my $user = $c->bugzilla->oauth('api:modify');
          if ($user && $user->id) {
            $user_id = $user->id;
          }
          else {
            Bugzilla->check_rate_limit('api_key_mismatch');
          }
        }
      }

      if ($user_id) {
        my $user = Bugzilla::User->check({id => $user_id, cache => 1});

        # Native /rest routes start in USAGE_MODE_REST (see
        # Bugzilla::App::Controller::API::_prepare_rest_request) and only some
        # handlers switch to USAGE_MODE_MOJO_REST before authenticating. The
        # legacy REST error path needs Bugzilla->_json_server, which only
        # rest.cgi ever creates, so normalize before raising anything below.
        if ($usage_mode == USAGE_MODE_REST) {
          Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
          $usage_mode = USAGE_MODE_MOJO_REST;
        }

        $c->bugzilla->assert_account_usable($user) or return undef;

        Bugzilla->set_user($user);
        return $user;
      }

      # Redirect to login page if we are a web page
      if ($usage_mode == USAGE_MODE_BROWSER || $usage_mode == USAGE_MODE_MOJO) {
        return $c->bugzilla->login_redirect_if_required($type);
      }

      # Return default user (non-authenticated)
      return Bugzilla->user;
    }
  );
}

1;
