# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Plugin::Error;
use 5.10.1;
use Mojo::Base 'Mojolicious::Plugin';

use Bugzilla::Constants;
use Bugzilla::Logging;
use Bugzilla::WebService::Constants;

my $EXCEPTION_HELPER;

sub register {
  my ($self, $app) = @_;

  # For Bugzilla::Error exceptions when using Mojo native
  # code and some function calls Throw{Code,User}Error().
  $EXCEPTION_HELPER = $app->renderer->get_helper('reply.exception');
  $app->helper('reply.exception' => sub { _render_error('code', @_); });

  $app->helper('code_error' => sub { _render_error('code', @_); });
  $app->helper('user_error' => sub { _render_error('user', @_); });
}

sub _render_error {
  my ($type, $c, $error, $vars, $options) = @_;
  $options ||= {};

  # If values are defined in the stash, use those instead
  my $stash = $c->stash;
  $type  = $stash->{type}  if $stash->{type};
  $error = $stash->{error} if $stash->{error};
  $vars  = $stash->{vars}  if $stash->{vars};

  my $logfunc = _make_logfunc(ucfirst($type));

  # Find the full error message
  my $message;
  $vars->{error} = $error;
  my $template = Bugzilla->template;
  $template->process("global/$type-error.html.tmpl", $vars, \$message)
    || die $template->error();

  # Errors displayed in a web page
  if (Bugzilla->usage_mode == USAGE_MODE_MOJO) {
    $logfunc->("webpage error: $error");

    if ($c->app->mode eq 'development' && !$options->{skip_exception_page}) {
      use Bugzilla::Logging;
      my $class = $type ? 'Bugzilla::Error::' . ucfirst($type) : 'Mojo::Exception';
      my $e     = $class->new($error)->trace(2);
      $e->vars($vars) if $e->can('vars');
      $EXCEPTION_HELPER->($c, $e->inspect);
      return 0;
    }
    else {
      $c->render(
        handler  => 'bugzilla',
        template => "global/$type-error",
        format   => 'html',
        error    => $error,
        %{$vars},
        status => $options->{status} // $vars->{status} // 200
      );
      return 0;
    }
  }

  # Errors returned in an API request
  elsif (Bugzilla->usage_mode == USAGE_MODE_MOJO_REST) {
    my %error_map = %{WS_ERROR_CODE()};
    my $code      = $error_map{$error};

    if (!$code) {
      $code = ERROR_UNKNOWN_FATAL     if $type =~ /code/i;
      $code = ERROR_UNKNOWN_TRANSIENT if $type =~ /user/i;
    }

    my %status_code_map = %{REST_STATUS_CODE_MAP()};
    my $status_code     = $status_code_map{$code} || $status_code_map{'_default'};

    $logfunc->("REST error: $error (HTTP $status_code, internal code $code)");

    my $error = {
      error         => 1,
      code          => $code,
      message       => $message,
      documentation => Bugzilla->localconfig->urlbase . 'docs/en/md/api/index.md',
    };

    $c->render(json => $error, status => $status_code);
    return 0;
  }
}

sub _make_logfunc {
  my ($type) = @_;
  my $logger = Log::Log4perl->get_logger("Bugzilla.Error.$type");
  return sub {
    local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 3;
    if ($type eq 'User') {
      $logger->warn(@_);
    }
    else {
      $logger->error(@_);
    }
  };
}

1;
