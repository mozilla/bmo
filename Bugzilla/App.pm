# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App;
use Mojo::Base 'Mojolicious';

# Needed for its exit() overload, must happen early in execution.
use CGI::Compile;
use utf8;
use Encode;
use FileHandle;    # this is for compat back to 5.10

use Bugzilla          ();
use Bugzilla::BugMail ();
use Bugzilla::CGI     ();
use Bugzilla::Constants;
use Bugzilla::Extension             ();
use Bugzilla::Install::Requirements ();
use Bugzilla::Logging;
use Bugzilla::App::Static;
use Mojo::Loader qw( find_modules );
use Module::Runtime qw( require_module );
use Bugzilla::Util qw(trim);
use Cwd qw(realpath);
use List::Util qw(any);
use MojoX::Log::Log4perl;
use Bugzilla::WebService::Server::REST;
use Try::Tiny;

has 'static' => sub { Bugzilla::App::Static->new };

sub startup {
  my ($self) = @_;
  $self->log(MojoX::Log::Log4perl->new);

  TRACE('Starting up');
  $self->plugin('Bugzilla::App::Plugin::BlockIP');
  $self->plugin('Bugzilla::App::Plugin::Glue');
  $self->plugin('Bugzilla::App::Plugin::Login');
  $self->plugin('Bugzilla::App::Plugin::Error');
  $self->plugin('Bugzilla::App::Plugin::RequestLimit');
  $self->plugin('Bugzilla::App::Plugin::Hostage')
    unless $ENV{BUGZILLA_DISABLE_HOSTAGE};
  $self->plugin('Bugzilla::App::Plugin::SizeLimit')
    unless $ENV{BUGZILLA_DISABLE_SIZELIMIT};
  $self->plugin('ForwardedFor') if Bugzilla->has_feature('better_xff');
  $self->plugin('Bugzilla::App::Plugin::Helpers');
  $self->plugin('Bugzilla::App::Plugin::OAuth2::Client');
  $self->plugin('Bugzilla::App::Plugin::OAuth2::Provider');

  push @{$self->commands->namespaces}, 'Bugzilla::App::Command';
  push @{$self->renderer->paths}, @{ Bugzilla::Template::_include_path() };

  $self->sessions->cookie_name('bugzilla');
  $self->sessions->default_expiration(60 * 60 * 24 * 7); # 1 week

  $self->hook(
    before_routes => sub {
      my ($c) = @_;
      return if $c->stash->{'mojo.static'};

      # It is possible the regexp is bad.
      # If that is the case, we just log the error and continue on.
      try {
        my $regexp = Bugzilla->params->{block_user_agent};
        my $user_agent = $c->req->headers->user_agent // '';
        if ($regexp && $user_agent =~ /$regexp/) {
          my $msg = "Contact " . Bugzilla->params->{maintainer};
          $c->respond_to(
            json => {json => {error => $msg}, status => 400},
            any  => {text => "$msg\n",        status => 400},
          );
        }
      }
      catch {
        ERROR($_);
      };

      # Set usage mode and store controller for Error.pm exception handling
      Bugzilla->usage_mode(USAGE_MODE_MOJO);
      Bugzilla->request_cache->{mojo_controller} = $c;
    }
  );

  $ENV{MOJO_MAX_LINE_SIZE} ||= 1024 * 10; # Mojo default is 8kb

  # hypnotoad is weird and doesn't look for MOJO_LISTEN itself.
  $self->config(
    hypnotoad => {
      proxy              => $ENV{MOJO_REVERSE_PROXY} // 1,
      heartbeat_interval => $ENV{MOJO_HEARTBEAT_INTERVAL} // 10,
      heartbeat_timeout  => $ENV{MOJO_HEARTBEAT_TIMEOUT} // 120,
      inactivity_timeout => $ENV{MOJO_INACTIVITY_TIMEOUT} // 120,
      workers            => $ENV{MOJO_WORKERS} // 1,
      clients            => $ENV{MOJO_CLIENTS} // 200,
      spare              => $ENV{MOJO_SPARE} // 1,
      listen             => [$ENV{MOJO_LISTEN} // 'http://*:3000'],
    },
  );

  # Make sure each httpd child receives a different random seed (bug 476622).
  # Bugzilla::RNG has one srand that needs to be called for
  # every process, and Perl has another. (Various Perl modules still use
  # the built-in rand(), even though we never use it in Bugzilla itself,
  # so we need to srand() both of them.)
  # Also, ping the dbh to force a reconnection.
  Mojo::IOLoop->next_tick(sub {
    Bugzilla::RNG::srand();
    srand();
    eval { Bugzilla->dbh->ping };
  });

  Bugzilla::Extension->load_all();
  if ($self->mode ne 'development') {
    Bugzilla->preload_features();
    DEBUG('preloading templates');
    Bugzilla->preload_templates();
    DEBUG('done preloading templates');
    require_module($_) for find_modules('Bugzilla::User::Setting');

    $self->hook(
      after_static => sub {
        my ($c) = @_;
        my $version = $c->stash->{static_file_version};
        if ($version && $version > Bugzilla->VERSION) {
          $c->res->headers->cache_control('no-cache, no-store');
        }
        else {
          $c->res->headers->cache_control('public, max-age=31536000, immutable');
        }
      }
    );
  }
  $self->hook(
    before_dispatch => sub {
      # Ensure the request_cache is always cleared prior to every request,
      # regardless of routing or Bugzilla::App wrapping.
      # This is not an expensive operation.
      Bugzilla->clear_request_cache();
      # We also need to clear CGI's globals.
      CGI::initialize_globals();
      # Store away the default controller for use by non-Mojo legacy code
      Bugzilla->request_cache->{mojo_controller} = $_[0];
    }
  );
  $self->hook(after_dispatch => sub {
    my ($c) = @_;
    my ($req, $res) = ($c->req, $c->res);

    if ( $req->is_secure
      && !$res->headers->strict_transport_security
      && Bugzilla->params->{'strict_transport_security'} ne 'off')
    {
      my $sts_opts = 'max-age=' . MAX_STS_AGE;
      if (Bugzilla->params->{'strict_transport_security'} eq 'include_subdomains') {
        $sts_opts .= '; includeSubDomains';
      }
      $res->headers->strict_transport_security($sts_opts);
    }

    # Add X-Frame-Options header to prevent framing and subsequent
    # possible clickjacking problems.
    unless ($c->url_is_attachment_base) {
      $res->headers->header('X-frame-options' => 'SAMEORIGIN');
    }

    # Add X-XSS-Protection header to prevent simple XSS attacks
    # and enforce the blocking (rather than the rewriting) mode.
    $res->headers->header('X-xss-protection' => '1; mode=block');

    # Add X-Content-Type-Options header to prevent browsers sniffing
    # the MIME type away from the declared Content-Type.
    $res->headers->header('X-content-type-options' => 'nosniff');

    if (length($req->url->to_abs->to_string) > 8000) {
      $res->headers->header('Referrer-policy' => 'origin');
    }
    else {
      $res->headers->header('Referrer-policy' => 'same-origin');
    }

    # Add Cross-Origin-Opener-Policy header if not already set
    # This header controls the relationship between browsing contexts
    # to prevent cross-origin attacks like Spectre.
    $res->headers->header(
      'Cross-Origin-Opener-Policy' => 'same-origin-allow-popups');

    # CSP only governs how a browser renders a document, so only documents get
    # the header (see CSP_DOCUMENT_TYPES). REST responses are consumed by
    # clients that neither apply a policy nor send violation reports, so a
    # policy there is read by nobody: it just adds ~1KB to every response and
    # costs a Bugzilla->user lookup plus a nonce to build (see the
    # content_security_policy helper in Bugzilla::App::Plugin::Glue).
    if (_response_is_document($res) && !$res->headers->content_security_policy) {
      if (my $csp = $c->content_security_policy) {
        $res->headers->header($csp->header_name, $csp->value);
      }
    }
  });
  Bugzilla::WebService::Server::REST->preload;

  $self->setup_routes;

  Bugzilla::Hook::process('app_startup', {app => $self});
}

# Legacy CGI responses reach here with their headers already parsed into the
# Mojo response (Bugzilla::CGI::header), and rendered responses have a content
# type set by the renderer, so this is decidable at after_dispatch time for
# both stacks.
#
# The status check is not redundant: a response that carries no body still gets
# a content type from the renderer, and it defaults to text/html. The CSP
# collector is exactly that shape -- render(data => '', status => 204) -- so
# without this it would look like a document and be handed a policy governing a
# page that does not exist.
#
# Redirects are the mirror image and are also left without a policy, though they
# reach that answer by the content type rather than the status: neither stack
# sets one on a 3xx (Mojolicious redirect_to calls rendered(), and CGI.pm's
# redirect() emits no Content-Type), so they fall through to "not a document".
# That is intended. A 3xx body is empty, so there is nothing for a policy to
# govern, and the browser applies the policy of the response it lands on. Do not
# "fix" this by treating an absent content type as a document: that hands a
# policy to every bodiless response, and t/csp-scope.t pins the current answer.
sub _response_is_document {
  my ($res) = @_;
  return 0 if $res->is_empty;

  # Compare the type on its own: a content type reaches us with parameters
  # attached ("text/html; charset=UTF-8") and in whatever case the CGI script
  # or renderer happened to use.
  my ($type) = split /;/, $res->headers->content_type // '';
  $type = lc trim($type // '');
  return 1 if any { $_ eq $type } CSP_DOCUMENT_TYPES;

  # The XML family is matched by shape rather than enumerated, so RDF and Atom
  # feeds, XHTML, inline SVG and XML attachments are all one rule.
  return $type =~ CSP_DOCUMENT_TYPE_RE ? 1 : 0;
}

sub setup_routes {
  my ($self) = @_;
  my $r = $self->routes;

  # Load controller modules and their routes
  foreach my $module (find_modules('Bugzilla::App::Controller', {recursive => 1}))
  {
    require_module($module);
    my $controller = $module->new;
    if ($controller->can('setup_routes')) {
      $controller->setup_routes($r);
    }
    else {
      WARN("Could not execute setup_routes() for module: $module");
    }
  }

  $r->static_file('/__lbheartbeat__');
  $r->static_file(
    '/__version__' => {file => 'version.json', content_type => 'application/json'});
  $r->static_file('/version.json', {content_type => 'application/json'});

  $r->page('/review',        'splinter.html');
  $r->page('/user_profile',  'user_profile.html');
  $r->page('/userprofile',   'user_profile.html');
  $r->page('/request_defer', 'request_defer.html');
}

1;
