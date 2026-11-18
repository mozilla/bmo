#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.get()                   #
# GET /rest/bug/<id>                                 #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use DateTime;
use QA::Util qw(get_config);
use QA::Tests qw(bug_tests PRIVATE_BUG_USER);
use QA::REST::Util qw(api_headers rest_get_url create_test_bugs test_bug);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

my $creation_time = DateTime->now();
my ($public_bug, $private_bug) = create_test_bugs($t, $config, $url,
  second_private => 1, no_cc => 1);
my $private_id = $private_bug->{id};
my $public_id  = $public_bug->{id};

my $base_url = $config->{browser_url} . '/';

# Set a few fields on the private bug, including a dependency relationship.
$t->put_ok($url . "rest/bug/$private_id" =>
    {'X-Bugzilla-API-Key' => $config->{PRIVATE_BUG_USER . '_user_api_key'}} =>
    json => {
      blocks                => {set => [$public_id]},
      dupe_of               => $public_id,
      is_creator_accessible => 0,
      see_also              => {
        add => [
          "${base_url}show_bug.cgi?id=$public_id",
          "https://bugzilla-dev.allizom.org/show_bug.cgi?id=123456"
        ]
      },
      cf_qa_status     => ['in progress', 'verified'],
      cf_single_select => 'two',
    })->status_is(200);

$private_bug->{blocks}                = [$public_id];
$private_bug->{dupe_of}               = $public_id;
$private_bug->{status}                = 'RESOLVED';
$private_bug->{is_open}               = 0;
$private_bug->{resolution}            = 'DUPLICATE';
$private_bug->{is_creator_accessible} = 0;
$private_bug->{is_cc_accessible}      = 1;
# PRIVATE_BUG_USER has no canconfirm, so cannot set keywords (Bug 2078325).
# They are set on the public bug by admin below instead.
$private_bug->{keywords}              = [];
$private_bug->{see_also}              = [
  "${base_url}show_bug.cgi?id=$public_id",
  "https://bugzilla-dev.allizom.org/show_bug.cgi?id=123456"
];
$private_bug->{cf_qa_status}     = ['in progress', 'verified'];
$private_bug->{cf_single_select} = 'two';

$public_bug->{dupe_of}               = undef;
$public_bug->{resolution}            = '';
$public_bug->{is_open}               = 1;
$public_bug->{is_creator_accessible} = 1;
$public_bug->{is_cc_accessible}      = 1;
$public_bug->{keywords}              = ['test-keyword-1', 'test-keyword-2'];

# Local Bugzilla bugs are automatically updated.
$public_bug->{cf_qa_status}     = [];
$public_bug->{cf_single_select} = '---';

# Fill in the time tracking fields on the public bug.
$t->put_ok($url . "rest/bug/$public_id" =>
    {'X-Bugzilla-API-Key' => $config->{admin_user_api_key}} => json => {
      deadline       => '2038-01-01',
      keywords       => {set => ['test-keyword-1', 'test-keyword-2']},
      estimated_time => '10.0',
      remaining_time => '5.0',
    })->status_is(200);

# Populate other fields.
$public_bug->{classification}  = 'Unclassified';
$private_bug->{classification} = 'Unclassified';
$private_bug->{groups}         = ['QA-Selenium-TEST'];
$public_bug->{groups}          = [];

# The user filing $private_bug doesn't have permission to set the status
# or qa_contact, so they differ from normal $public_bug values.
$private_bug->{qa_contact} = $config->{PRIVATE_BUG_USER . '_user_login'};

# PRIVATE_BUG_USER has no editbugs, so severity is reset (Bug 2078325).
$private_bug->{severity} = Bugzilla->params->{defaultseverity};

sub check_bug {
  my ($test, $json) = @_;

  is(scalar @{$json->{bugs}}, 1, "Got exactly one bug");
  my $bug = $json->{bugs}->[0];
  my $is_private_bug = $bug->{id} == $private_bug->{id};
  my $is_privileged_user
    = $test->{user}
    && ($test->{user} eq 'editbugs'
    || $test->{user} eq 'admin'
    || $test->{user} eq PRIVATE_BUG_USER);

  if ($test->{user} && $test->{user} eq 'admin') {
    ok(exists $bug->{estimated_time} && exists $bug->{remaining_time},
      'Admin correctly gets time-tracking fields');
    is($bug->{deadline}, '2038-01-01', 'deadline is correct');
    cmp_ok($bug->{estimated_time}, '==', '10.0', 'estimated_time is correct');
    cmp_ok($bug->{remaining_time}, '==', '5.0',  'remaining_time is correct');
  }
  else {
    ok(
      !exists $bug->{estimated_time} && !exists $bug->{remaining_time},
      'Time-tracking fields are not returned to non-privileged users'
    );
  }

  # See also to a private bug should not display for the public bug
  if (!$is_private_bug && !$is_privileged_user) {
    ok(
      !exists $bug->{see_also} || !@{$bug->{see_also}},
      'See also to a private bug should not display for the public bug and normal user'
    );
  }

  if (exists $bug->{depends_on}) {
    is_deeply(
      $bug->{depends_on},
      $is_private_bug ? [] : $is_privileged_user ? [$private_id] : [],
      $is_private_bug ? 'depends_on value is correct'
      : $is_privileged_user
      ? 'Private bug ID in depends_on is returned to privileged bug user'
      : 'Private bug ID in depends_on is not returned to non-privileged bug user'
        . ($test->{user} ? ' (' . $test->{user} . ')' : '')
    );
  }

  my $expect = $is_private_bug ? $private_bug : $public_bug;

  my @fields = sort keys %$expect;
  push(@fields, 'creation_time', 'last_change_time');

  test_bug(\@fields, $bug, $expect, $test, $creation_time);
}

my @tests = (
  @{bug_tests($public_id, $private_id)},
  {
    args => {ids => [$public_id], include_fields => ['id', 'summary', 'groups']},
    test => 'include_fields',
  },
  {
    args =>
      {ids => [$public_id], exclude_fields => ['assigned_to', 'cf_qa_status']},
    test => 'exclude_fields'
  },
  {
    args => {
      ids            => [$public_id],
      include_fields => ['id', 'summary', 'groups'],
      exclude_fields => ['summary']
    },
    test => 'exclude_fields overrides include_fields'
  },
  {
    user => 'editbugs',
    args => {ids => [$public_id], include_fields => ['id', 'depends_on']},
    test => 'editbugs can see private ids in bug references',
  },
);

foreach my $test (@tests) {
  my $id = $test->{args}{ids}[0];

  # The RPC-only "undef bug id" case has no single-resource REST URL.
  next if !defined $id;

  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my %query;
  for my $f (qw(include_fields exclude_fields)) {
    $query{$f} = $test->{args}{$f} if exists $test->{args}{$f};
  }
  my $req = rest_get_url($url, "rest/bug/$id", \%query);

  if (my $error = $test->{error}) {
    $t->get_ok($req => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
  }
  else {
    $t->get_ok($req => $headers)->status_is(200);
    check_bug($test, $t->tx->res->json);
  }
}

done_testing();
