#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Bug;
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $user = Bugzilla::User->check({id => 1});
Bugzilla->set_user($user);

my $bug_1 = Bugzilla::Bug->create({
  short_desc => 'A test bug',
  product    => 'Firefox',
  component  => 'General',
  bug_type     => 'defect',
  bug_severity => 'normal',
  groups       => [],
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => 'Trunk',
  keywords     => [],
  cc           => [],
  comment      => 'This is a brand new bug',
  assigned_to  => 'nobody@mozilla.org',
});
ok($bug_1->id, "got a new bug");

my $urlbase  = Bugzilla->localconfig->urlbase;
my $bug_1_id = $bug_1->id;
my $bug_2    = Bugzilla::Bug->create({
  short_desc => 'A bug that references another bug',
  product    => 'Firefox',
  component  => 'General',
  ,
  bug_type     => 'defect',
  bug_severity => 'normal',
  groups       => [],
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => 'Trunk',
  keywords     => [],
  cc           => [],
  comment      => "This is related to ${urlbase}show_bug.cgi?id=$bug_1_id",
  assigned_to  => 'nobody@mozilla.org',
});

my $bug_2_id = $bug_2->id;

Bugzilla::Template::quoteUrls(
  $bug_2->comments->[0]->body,
  undef, undef, undef,
  sub {
    my $bug_id = $_[0];
    is($bug_id, $bug_1_id, "found Bug $bug_1_id on Bug $bug_2_id");
  }
);

# A URL without "//" after the scheme would be resolved by browsers as a
# relative path on the current site, so it must not be linkified.
my $single_slash
  = Bugzilla::Template::quoteUrls('https:/bugzilla.mozilla.org/home');
unlike($single_slash, qr/<a\b/, 'single-slash https URL is not linkified');
is($single_slash, 'https:/bugzilla.mozilla.org/home',
  'single-slash https URL is left as plain text');

my $no_slash = Bugzilla::Template::quoteUrls('https:bugzilla.mozilla.org/home');
unlike($no_slash, qr/<a\b/, 'no-slash https URL is not linkified');
is($no_slash, 'https:bugzilla.mozilla.org/home',
  'no-slash https URL is left as plain text');

like(
  Bugzilla::Template::quoteUrls('https://bugzilla.mozilla.org/home'),
  qr{<a [^>]*href="https://bugzilla\.mozilla\.org/home"},
  'double-slash https URL is still linkified'
);

like(
  Bugzilla::Template::quoteUrls('news:comp.lang.perl'),
  qr{<a [^>]*href="news:comp\.lang\.perl"},
  'non-hierarchical scheme without slashes is still linkified'
);

done_testing;
