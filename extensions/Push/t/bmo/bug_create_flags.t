#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# A bug created with a flag already set is pushed twice in one request: once
# by bug_end_of_create (before its flags exist) and again by bug_end_of_update
# (when they are set).  The second push must include the flags in 'bug.flags'.

use 5.10.1;
use strict;
use warnings;
use lib qw( . lib local/lib/perl5 );

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Bug;
use Bugzilla::WebService::Util qw(extract_flags);
BEGIN { Bugzilla->extensions }

use Test2::V0;
use Test2::Tools::Mock qw(mock);

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $user = Bugzilla::User->check({id => 1});
Bugzilla->set_user($user);

# pretend push is enabled without needing configured connectors; with none
# enabled _push_object still builds each message but doesn't store it.
Bugzilla->request_cache->{'Bugzilla::Extension::Push'} = {enabled => 1};

my @messages;
my $Message = mock 'Bugzilla::Extension::Push::Message' => (
  around => [
    new_transient => sub {
      my $orig    = shift;
      my $message = $orig->(@_);
      push @messages, $message->payload_decoded;
      return $message;
    },
  ],
);

my $bug = Bugzilla::Bug->create({
  short_desc   => 'Push payload for a bug created with a flag',
  product      => 'Firefox',
  component    => 'General',
  bug_type     => 'defect',
  bug_severity => 'normal',
  groups       => [],
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => 'Trunk',
  keywords     => [],
  cc           => [],
  comment      => 'This bug is created with a flag set',
  assigned_to  => 'nobody@mozilla.org',
});
ok($bug->id, 'created a bug');

# set the flag the same way the REST API does when creating a bug
my ($flags, $new_flags)
  = extract_flags([{name => 'qe-verify', status => '+'}], $bug);
$bug->set_flags($flags, $new_flags);
$bug->update($bug->creation_ts);

my ($create)
  = grep { $_->{event}{target} eq 'bug' && $_->{event}{action} eq 'create' }
  @messages;
ok($create, 'bug.create was pushed');
is($create->{bug}{flags}, [], 'bug.create has no flags yet') if $create;

my ($modify) = grep {
  $_->{event}{target} eq 'bug'
    && $_->{event}{action} eq 'modify'
    && grep { $_->{field} eq 'flag.qe-verify' } @{$_->{event}{changes}}
} @messages;
ok($modify, 'bug.modify for the flag was pushed');
if ($modify) {
  is(
    [map { [$_->{name}, $_->{value}] } @{$modify->{bug}{flags}}],
    [['qe-verify', '+']],
    'bug.modify payload includes the flag set at creation'
  );
}

done_testing;
