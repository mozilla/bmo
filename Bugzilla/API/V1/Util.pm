# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Util;

use 5.10.1;
use strict;
use warnings;

use Mojo::JSON qw(true false);

use Bugzilla;
use Bugzilla::Util qw(datetime_from email_filter);

use MIME::Base64 qw(encode_base64);

# Same output as type() on the legacy JSON-RPC/REST server.
sub type {
  my ($class, $type, $value) = @_;

  # This is the only type that does something special with undef.
  return $value ? true : false if $type eq 'boolean';

  return undef        if !defined $value;
  return int($value)  if $type eq 'int';
  return 0.0 + $value if $type eq 'double';
  return "$value"     if $type eq 'string';
  return email_filter($value)
    if $type eq 'email' && Bugzilla->params->{webservice_email_filter};

  # Always UTC, with the timezone specifier.
  return $value ? datetime_from($value, 'UTC')->iso8601() . 'Z' : ''
    if $type eq 'dateTime';

  if ($type eq 'base64') {
    utf8::encode($value) if utf8::is_utf8($value);
    return encode_base64($value, '');
  }

  return $value;
}

1;
