#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.possible_duplicates()   #
# GET /rest/bug/possible_duplicates                 #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Mojo::URL;
use QA::Util qw(get_config random_string);
use QA::Tests qw(create_bug_fields PRIVATE_BUG_USER);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url    = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Unique words so the full-text search only matches the bugs created here.
my $public_word = lc random_string(16);
my $secret_word = lc random_string(16);

sub create_bug {
  my ($api_key, %fields) = @_;
  my $bug = create_bug_fields($config);
  %$bug = (%$bug, %fields);
  $t->post_ok($url . 'rest/bug' => api_headers($api_key) => json => $bug)
    ->status_is(200);
  return $t->tx->res->json->{id};
}

my $public_id = create_bug(
  $config->{editbugs_user_api_key},
  summary => "possible duplicates $public_word",
);
my $private_id = create_bug(
  $config->{PRIVATE_BUG_USER . '_user_api_key'},
  summary          => "possible duplicates $secret_word",
  product          => 'QA-Selenium-TEST',
  component        => 'QA-Selenium-TEST',
  target_milestone => 'QAMilestone',
  version          => 'QAVersion',
  creator          => $config->{PRIVATE_BUG_USER . '_user_login'},

  # CC a user outside the bug's groups; involvement alone grants visibility.
  cc                => [$config->{unprivileged_user_login}],
  cclist_accessible => 1,
);

sub dupe_ids {
  my ($summary, $api_key) = @_;
  my $req = Mojo::URL->new($url . 'rest/bug/possible_duplicates')
    ->query(summary => $summary, limit => 1, include_fields => 'id');
  $t->get_ok($req => api_headers($api_key))->status_is(200);
  return [map { $_->{id} } @{$t->tx->res->json->{bugs}}];
}

# The private bug ranks first for its own secret word. Make sure the user
# who can see it gets it back, so the anonymous checks below are meaningful.
is_deeply(
  dupe_ids("$secret_word $public_word",
    $config->{PRIVATE_BUG_USER . '_user_api_key'}),
  [$private_id],
  'Privileged user gets the top-ranked private bug'
);

# A user who sees the private bug only through involvement (CC), not group
# membership, must not have it filtered out before the limit is applied.
is_deeply(
  dupe_ids("$secret_word $public_word", $config->{unprivileged_user_api_key}),
  [$private_id],
  'CC-only user gets the top-ranked private bug they can see'
);

# Anonymous users must get the same answer whether or not the probe matches
# a hidden summary; an empty result would leak the private summary's words.
is_deeply(dupe_ids("$secret_word $public_word"),
  [$public_id], 'Matching a private summary does not consume the result slot');
is_deeply(
  dupe_ids(lc(random_string(16)) . " $public_word"),
  [$public_id], 'Non-matching probe returns the public bug'
);

# MySQL boolean-mode operators must not reopen the oracle.
my $prefix = substr($secret_word, 0, 4);
is_deeply(dupe_ids(qq{$prefix*"zz"q zz"q"<$public_word}),
  [$public_id], 'Boolean-mode prefix probe does not leak private summary');

is_deeply(dupe_ids($secret_word), [], 'Private bug is never returned');

done_testing();
