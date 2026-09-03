# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package main;

use strict;
use warnings;
use 5.10.1;
use lib qw(. lib local/lib/perl5 extensions/SecureMail/lib);

use Test::More;
use Email::MIME;

BEGIN {
  *Bugzilla::Extension::SecureMail::NAME = sub { 1 };
}

my $extension = './extensions/SecureMail/Extension.pm';
require $extension;

my $email = Email::MIME->create(
  attributes => {content_type => 'multipart/alternative'},
  parts      => [],
);
my $control_part = Email::MIME->create(
  attributes => {
    content_type => 'application/pgp-encrypted',
    encoding     => '7bit',
  },
  body => "Version: 1\n",
);
my $data_part = Email::MIME->create(
  attributes => {
    content_type => 'application/octet-stream',
    encoding     => '7bit',
  },
  body => 'encrypted data',
);
my $encrypted_part = Email::MIME->create(
  attributes => {content_type => 'multipart/encrypted'},
  parts      => [$control_part, $data_part],
);

Bugzilla::Extension::SecureMail::_wrap_pgp_bugmail(
  $email,
  $encrypted_part,
  'https://bugzilla.example/show_bug.cgi?id=123',
);

like($email->content_type, qr{\Amultipart/mixed(?:;|\z)},
  'outer message is multipart/mixed');
my @outer_parts = $email->parts;
is(scalar @outer_parts, 2, 'outer message contains the link and encrypted message');
like($outer_parts[0]->content_type, qr{\Atext/plain(?:;|\z)},
  'first part is plaintext');
like($outer_parts[0]->body_str,
  qr{\AView this bug: https://bugzilla\.example/show_bug\.cgi\?id=123\r?\n\z},
  'plaintext part contains the bug URL');
like($outer_parts[1]->content_type, qr{\Amultipart/encrypted(?:;|\z)},
  'second part is the PGP/MIME message');
my @encrypted_parts = $outer_parts[1]->parts;
is(scalar @encrypted_parts, 2, 'PGP/MIME message retains its two required parts');
is($encrypted_parts[0]->content_type, 'application/pgp-encrypted',
  'first PGP/MIME part is the control information');
is($encrypted_parts[1]->content_type, 'application/octet-stream',
  'second PGP/MIME part is encrypted data');

my $unwrapped_email = Email::MIME->create(
  attributes => {content_type => 'multipart/alternative'},
  parts      => [],
);
$unwrapped_email->parts_set([$control_part, $data_part]);
Bugzilla::Extension::SecureMail::_set_pgp_content_type($unwrapped_email);
my ($boundary) = $unwrapped_email->header('Content-Type') =~ /boundary="([^"]+)"/;
is($boundary, $unwrapped_email->{ct}{attributes}{boundary},
  'unwrapped PGP/MIME header declares its own generated boundary');
like($unwrapped_email->as_string, qr/--\Q$boundary\E/,
  'unwrapped PGP/MIME body uses its declared boundary');

done_testing;
