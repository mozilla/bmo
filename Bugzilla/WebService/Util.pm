# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::WebService::Util;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Hook;
use Bugzilla::WebService::Constants;

use URI::Escape qw(uri_unescape);

use base qw(Exporter);

# We have to "require", not "use" this, because otherwise it tries to
# use features of Test::More during import().
require Test::Taint if ${^TAINT};

our @EXPORT_OK = qw(
  taint_data
  fix_credentials
);

sub taint_data {
  my @params = @_;
  return if !@params;

  # Though this is a private function, it hasn't changed since 2004 and
  # should be safe to use, and prevents us from having to write it ourselves
  # or require another module to do it.
  if (${^TAINT}) {
    Test::Taint::_deeply_traverse(\&_delete_bad_keys, \@params);
    Test::Taint::taint_deeply(\@params);
  }
}

sub _delete_bad_keys {
  foreach my $item (@_) {
    next if ref $item ne 'HASH';
    foreach my $key (keys %$item) {

      # Making something a hash key always untaints it, in Perl.
      # However, we need to validate our argument names in some way.
      # We know that all hash keys passed in to the WebService will
      # match \w+, so we delete any key that doesn't match that.
      if ($key !~ /^[\w\.\-]+$/) {
        delete $item->{$key};
      }
    }
  }
  return @_;
}

sub fix_credentials {
  my ($params, $cgi) = @_;

  # Allow user to pass in authentication details in X-Headers
  # This allows callers to keep credentials out of GET request query-strings.
  # Headers always take precedence over body-supplied credentials to prevent
  # body-injected params from overriding gateway/middleware auth headers.
  if ($cgi) {
    foreach my $field (keys %{API_AUTH_HEADERS()}) {
      next if ($cgi->http($field) // '') eq '';
      $params->{API_AUTH_HEADERS->{$field}} = uri_unescape($cgi->http($field));
    }
  }

  # Allow user to pass in login=foo&password=bar as a convenience
  # even if not calling GET /login.
  # Headers take precedence: always remove body params but only promote
  # them to Bugzilla_* keys when headers haven't already set those keys.
  if (exists $params->{'login'} && exists $params->{'password'}) {
    my ($body_login, $body_password)
      = (delete $params->{'login'}, delete $params->{'password'});
    $params->{'Bugzilla_login'}    //= $body_login;
    $params->{'Bugzilla_password'} //= $body_password;
  }

  # Allow user to pass api_key=12345678 as a convenience which becomes
  # "Bugzilla_api_key" which is what the auth code looks for.
  # Headers take precedence: always remove body param but only promote
  # it when headers haven't already set Bugzilla_api_key.
  if (exists $params->{api_key}) {
    my $body_api_key = delete $params->{api_key};
    $params->{Bugzilla_api_key} //= $body_api_key;
  }

  # Allow user to pass token=12345678 as a convenience which becomes
  # "Bugzilla_token" which is what the auth code looks for.
  # Headers take precedence: always remove body param but only promote
  # it when headers haven't already set Bugzilla_token.
  if (exists $params->{'token'}) {
    my $body_token = delete $params->{'token'};
    $params->{'Bugzilla_token'} //= $body_token;
  }

  # Allow extensions to modify the credential data before login
  Bugzilla::Hook::process('webservice_fix_credentials', {params => $params});
}

__END__

=head1 NAME

Bugzilla::WebService::Util - Utility functions used only by the legacy
WebService server. The helpers shared with the native API are in
L<Bugzilla::API::V1::Util>.

=head1 SYNOPSIS

 taint_data(@params);
 fix_credentials($params, $cgi);

=head1 METHODS

=head2 fix_credentials

Allows for certain parameters related to authentication such as Bugzilla_login,
Bugzilla_password, and Bugzilla_token to have shorter named equivalents passed in.
This function converts the shorter versions to their respective internal names.

=head1 B<Methods in need of POD>

=over

=item taint_data

=back
