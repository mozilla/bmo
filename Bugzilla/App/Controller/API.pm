# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Controller::API;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use File::Basename qw(basename);
use Mojo::Loader qw( find_modules );
use Module::Runtime qw(require_module);
use Try::Tiny;

use Bugzilla::Constants;
use Bugzilla::Logging;
use Bugzilla::WebService::Util qw(set_rest_cors_headers);

use constant SUPPORTED_VERSIONS => qw(V1);

sub setup_routes {
  my ($class, $r) = @_;

  # Add Bugzilla::API and Bugzilla::Extension to
  # namespaces for searching for API controllers
  my $namespaces = $r->namespaces;
  push @$namespaces, 'Bugzilla::API', 'Bugzilla::Extension';
  $r->namespaces($namespaces);

  # Backwards compat with /api/user/profile which Phabricator requires
  $r->under('/api' => \&_prepare_rest_request)
    ->get('/user/profile')->to('V1::User#user_profile');

  # Other backwards compat routes
  $r->under('/latest' => \&_prepare_rest_request)
    ->get('/configuration')->to('V1::Configuration#configuration');
  $r->under('/bzapi' => \&_prepare_rest_request)
    ->get('/configuration')->to('V1::Configuration#configuration');

  # Set the usage mode for all routes under /rest
  my $rest_routes = $r->under('/rest' => \&_prepare_rest_request);

  # Standard API support
  foreach my $version (SUPPORTED_VERSIONS) {
    foreach my $module (find_modules("Bugzilla::API::$version")) {
      _load_api_module($rest_routes, $module);
    }
  }

  # Extension API support
  my @ext_paths     = glob bz_locations()->{'extensionsdir'} . '/*';
  my @ext_api_paths = grep { !-e "$_/disabled" && -d "$_/lib/API" } @ext_paths;

  foreach my $version (SUPPORTED_VERSIONS) {
    foreach my $ext_path (@ext_api_paths) {
      my $ext_name = $ext_path;
      $ext_name =~ s|^.*extensions/||;

      my @module_paths = glob "$ext_path/lib/API/$version/*";
      foreach my $module_path (@module_paths) {
        my $module = "Bugzilla::Extension::${ext_name}::API::${version}::"
          . basename($module_path, '.pm');
        _load_api_module($rest_routes, $module);
      }
    }
  }
}

sub _prepare_rest_request {
  my ($c) = @_;
  _insert_rest_headers($c);
  $c->stash->{request_limit_format} = 'rest';
  Bugzilla->usage_mode(USAGE_MODE_REST);
  return 1;
}

sub _load_api_module {
  my ($routes, $module) = @_;
  try {
    require_module($module);

    # Helper modules such as Bugzilla::API::V1::Util live in the same
    # namespace but are not controllers: nothing to instantiate or route.
    $module->new->setup_routes($routes) if $module->can('setup_routes');
  }
  catch {
    WARN("$module could not be loaded: $_");
  };
}

sub _insert_rest_headers {
  my ($c) = @_;
  my @allowed_headers
    = qw(accept authorization content-type origin user-agent x-bugzilla-api-key x-requested-with);
  set_rest_cors_headers($c->res->headers, \@allowed_headers);
}

1;
