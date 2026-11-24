#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.create()                #
# POST /rest/bug                                     #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Storable qw(dclone);
use QA::Util qw(get_config random_string);
use QA::Tests qw(create_bug_fields PRIVATE_BUG_USER);
use QA::REST::Util qw(api_headers test_bug);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

my $bug_fields = create_bug_fields($config);

# hash to contain all the possible $bug_fields values that
# can be passed to createBug()
my $fields = {
  summary => {
    undefined =>
      {faultstring => 'You must enter a summary for this bug', value => undef},
  },

  product => {
    undefined =>
      {faultstring => 'You must select/enter a product.', value => undef},
    invalid => {faultstring => 'does not exist', value => 'does-not-exist'},
  },

  component => {
    undefined =>
      {faultstring => 'you must first choose a component', value => undef},
    invalid => {
      faultstring => "There is no component named 'does-not-exist'",
      value       => 'does-not-exist'
    },
  },

  version => {
    invalid => {
      faultstring => "There is no version named 'does-not-exist'.",
      value       => 'does-not-exist'
    },
  },
  platform => {
    undefined => {faultstring => 'You must select/enter a Hardware.', value => ''},
    invalid   => {
      faultstring => "There is no Hardware named 'does-not-exist'.",
      value       => 'does-not-exist'
    },
  },

  status => {
    invalid => {
      faultstring => "There is no status named 'does-not-exist'",
      value       => 'does-not-exist'
    },
  },

  type => {
    undefined => {faultstring => 'you must first choose a type', value => undef},
    invalid   => {
      faultstring => "There is no Type named 'does-not-exist'.",
      value       => 'does-not-exist'
    },
  },

  severity => {
    undefined => {faultstring => 'You must select/enter a Severity.', value => ''},
    invalid   => {
      faultstring => "There is no Severity named 'does-not-exist'.",
      value       => 'does-not-exist'
    },
  },

  priority => {
    undefined => {faultstring => 'You must select/enter a Priority.', value => ''},
    invalid   => {
      faultstring => "There is no Priority named 'does-not-exist'.",
      value       => 'does-not-exist'
    },
  },

  op_sys => {
    undefined => {faultstring => 'You must select/enter a OS.', value => ''},
    invalid   => {
      faultstring => "There is no OS named 'does-not-exist'.",
      value       => 'does-not-exist'
    },
  },

  cc => {
    invalid =>
      {faultstring => 'not a valid username', value => ['nonuserATbugillaDOTorg']},
  },

  assigned_to => {
    invalid => {
      faultstring => "There is no user named 'does-not-exist'",
      value       => 'does-not-exist'
    },
  },
  qa_contact => {
    invalid => {
      faultstring => "There is no user named 'does-not-exist'",
      value       => 'does-not-exist'
    },
  },
  alias => {
    long => {
      faultstring => 'Bug aliases cannot be longer than 20 characters',
      value       => 'MyyyyyyyyyyyyyyyyyyBugggggggggggggggggggggg'
    },
    existing => {faultstring => 'already taken the alias', value => 'public_bug'},
    numeric =>
      {faultstring => 'aliases cannot be merely numbers', value => '12345'},
    commma_or_space_separated => {
      faultstring => 'contains one or more commas or spaces',
      value       => 'Bug 12345'
    },

  },
  groups => {
    non_existent => {
      faultstring =>
        'either this group does not exist, or you are not allowed to restrict bugs to this group',
      value => [random_string(20)],
    },
  },
  comment_is_private => {
    invalid =>
      {faultstring => 'you are not allowed to.+comments.+private', value => 1,}
  },
  url => {
    javascript => {
      faultstring => 'is not a valid URL for the URL field',
      value       => 'javascript:alert(document.domain)//',
    },
    data => {
      faultstring => 'is not a valid URL for the URL field',
      value       => 'data:text/html,<script>alert(1)</script>',
    },
    vbscript => {
      faultstring => 'is not a valid URL for the URL field',
      value       => 'vbscript:msgbox(1)',
    },
  },
};

my @tests = (
  {
    args  => $bug_fields,
    error => "You must log in",
    test  => "Cannot file bugs as a logged-out user",
  },
  {
    user => PRIVATE_BUG_USER,
    args => {
      %$bug_fields,
      type             => 'defect',
      product          => 'QA-Selenium-TEST',
      component        => 'QA-Selenium-TEST',
      target_milestone => 'QAMilestone',
      version          => 'QAVersion',
      groups           => ['QA-Selenium-TEST'],
      qa_contact       => $config->{PRIVATE_BUG_USER . '_user_login'},
      status           => 'UNCONFIRMED'
    },

    # PRIVATE_BUG_USER has no editbugs, so severity is reset (Bug 2078325).
    expect => {severity => Bugzilla->params->{defaultseverity}},
    test   => "Authorized user can file a bug against a group",
  },
  {
    user => PRIVATE_BUG_USER,
    args => {
      %$bug_fields,
      comment_is_private => 1,
      assigned_to        => $config->{'permanent_user_login'},
      qa_contact         => '',
      status             => 'UNCONFIRMED'
    },
    expect => {severity => Bugzilla->params->{defaultseverity}},
    test   => "Insider can create a private description"
  },
  {
    user => 'editbugs',
    args => $bug_fields,
    test => "Creating a bug with standard values succeeds",
  },
);

# Convert the $fields tests into the standard test table format.
foreach my $field (sort keys %$fields) {
  my $test_values = $fields->{$field};
  foreach my $test_name (sort keys %$test_values) {
    my $input_fields = dclone($bug_fields);
    my $check_value  = $test_values->{$test_name}->{value};
    my $error        = $test_values->{$test_name}->{faultstring};
    $input_fields->{$field} = $check_value;
    push(@tests,
      {
        user  => 'editbugs',
        args  => $input_fields,
        error => $error,
        test  => "$field $test_name: fails as expected"
      });
  }
}

sub post_success {
  my ($test, $json, $api_key) = @_;

  my $id = $json->{id};
  ok($id, "Result has an id: $id");

  $t->get_ok($url . "rest/bug/$id" => api_headers($api_key))->status_is(200);
  my $bug = $t->tx->res->json->{bugs}->[0];

  my $expect = dclone $test->{args};
  %$expect = (%$expect, %{$test->{expect} || {}});
  my $comment_is_private = delete $expect->{comment_is_private};
  $expect->{creator} = $config->{$test->{user} . '_user_login'};

  my @fields = keys %$expect;
  test_bug(\@fields, $bug, $expect, $test);

  $t->get_ok($url . "rest/bug/$id/comment" => api_headers($api_key))
    ->status_is(200);
  my $comment = $t->tx->res->json->{bugs}->{$id}->{comments}->[0];
  is(
    $comment->{is_private} ? 1 : 0,
    $comment_is_private    ? 1 : 0,
    "comment privacy is correct"
  );
}

foreach my $test (@tests) {
  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);

  if (my $error = $test->{error}) {
    $t->post_ok($url . 'rest/bug' => $headers => json => $test->{args})
      ->status_isnt(200);
    like($t->tx->res->json->{message}, qr/$error/, "$test->{test}");
  }
  else {
    $t->post_ok($url . 'rest/bug' => $headers => json => $test->{args})
      ->status_is(200);
    post_success($test, $t->tx->res->json, $api_key);
  }
}

# Severity and priority need editbugs, also when filing a bug (Bug 2078325).
# Without it the requested values are silently reset to the defaults
# (defaultseverity / defaultpriority), so API clients keep working. canconfirm
# is not enough. Requested values differ from the QA defaults ('--' / 'Highest')
# so a reset is observable.
my %restricted_create = (
  product     => 'Another Product',
  component   => 'c1',
  version     => 'unspecified',
  summary     => 'Restricted severity/priority on create',
  description => 'Filed by rest_bug_create.t',
  type        => 'defect',
  op_sys      => 'Linux',
  platform    => 'PC',
  severity    => 'critical',
  priority    => 'High',
);
my $default_severity = Bugzilla->params->{defaultseverity};
my $default_priority = Bugzilla->params->{defaultpriority};

my @restricted_tests = (
  {
    user     => 'unprivileged',
    severity => $default_severity,
    priority => $default_priority
  },
  {
    user     => 'canconfirm',
    severity => $default_severity,
    priority => $default_priority
  },
  {user => 'editbugs', severity => 'critical', priority => 'High'},
);

foreach my $test (@restricted_tests) {
  my $user    = $test->{user};
  my $headers = api_headers($config->{"${user}_user_api_key"});

  $t->post_ok($url . 'rest/bug' => $headers => json => \%restricted_create)
    ->status_is(200);
  my $id = $t->tx->res->json->{id};
  ok($id, "$user: bug created with id " . ($id // 'undef'));

  $t->get_ok($url . "rest/bug/$id" => $headers)->status_is(200)->json_is(
    '/bugs/0/severity' => $test->{severity},
    "$user: severity is $test->{severity}"
  )->json_is(
    '/bugs/0/priority' => $test->{priority},
    "$user: priority is $test->{priority}"
  )->json_is('/bugs/0/type' => 'defect', "$user: type is kept");
}

done_testing();
