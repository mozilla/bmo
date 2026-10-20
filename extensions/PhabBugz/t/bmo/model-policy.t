#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# PhabBugz::Policy: policy.query lookups, custom policy creation with
# policy.create, and resolving the projects named in policy rules.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test::More;
use Test2::Tools::Exception qw(dies);
use Try::Tiny;

use Bugzilla::Extension::PhabBugz::Policy;
use Bugzilla::Extension::PhabBugz::Project;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

use constant Policy  => 'Bugzilla::Extension::PhabBugz::Policy';
use constant Project => 'Bugzilla::Extension::PhabBugz::Project';

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

my $group_a = $conduit->add_project(project_obj(name => $env->unique('bmo-a')));
my $group_b = $conduit->add_project(project_obj(name => $env->unique('bmo-b')));
my $secure  = $conduit->add_project(project_obj(name => 'secure-revision'));

my $existing = $conduit->add_policy(policy_obj(
  rules => [
    {
      action => 'allow',
      rule   => 'PhabricatorSubscriptionsSubscribersPolicyRule',
      value  => undef,
    },
    {
      action => 'allow',
      rule   => 'PhabricatorProjectsPolicyRule',
      value  => [$group_a->{phid}, $group_b->{phid}],
    },
  ],
));

# new_from_query
{
  $conduit->reset_calls;
  my $policy = Policy->new_from_query({phids => [$existing->{phid}]});
  is_deeply(
    [$conduit->calls('policy.query')],
    [{phids => [$existing->{phid}]}],
    'policy.query params'
  );
  is($policy->phid,            $existing->{phid}, 'phid');
  is($policy->type,            'custom',          'type');
  is($policy->default,         'deny',            'default action');
  is($policy->icon,            'fa-certificate',  'icon');
  is(scalar @{$policy->rules}, 2,                 'rules');

  ok(!Policy->new_from_query({phids => ['PHID-PLCY-missing']}),
    'unknown policy finds nothing');

  ok(dies { Policy->new_from_query({ids => [1]}) },
    'new_from_query only accepts phids');
}

# rule_projects resolves the project rule
{
  my $policy = Policy->new_from_query({phids => [$existing->{phid}]});
  $conduit->reset_calls;
  is_deeply(
    [map { $_->phid } @{$policy->rule_projects}],
    [$group_a->{phid}, $group_b->{phid}],
    'rule_projects returns the projects of the projects rule'
  );
  is($conduit->call_count('project.search'), 2, 'one project.search per project');

  my $no_projects = Policy->new(policy_obj(
    rules => [{
      action => 'allow',
      rule   => 'PhabricatorDifferentialReviewersPolicyRule',
      value  => undef,
    }]
  ));
  is_deeply($no_projects->rule_projects, [], 'policy without a projects rule');

  my $all_rule = Policy->new(policy_obj(
    rules => [{
      action => 'allow',
      rule   => 'PhabricatorProjectsAllPolicyRule',
      value  => [$group_b->{phid}],
    }]
  ));
  is_deeply(
    [map { $_->phid } @{$all_rule->rule_projects}],
    [$group_b->{phid}],
    'PhabricatorProjectsAllPolicyRule is recognised'
  );
}

# create with projects
{
  my @projects
    = map { Project->new_from_query({phids => [$_->{phid}]}) } $group_a, $group_b;

  $conduit->reset_calls;
  my $policy = Policy->create(\@projects);

  my ($create) = $conduit->calls('policy.create');
  is_deeply(
    $create,
    {
      objectType => 'DREV',
      default    => 'deny',
      policy     => [
        {action => 'allow', rule => 'PhabricatorSubscriptionsSubscribersPolicyRule'},
        {action => 'allow', rule => 'PhabricatorDifferentialReviewersPolicyRule'},
        {
          action => 'allow',
          rule   => 'PhabricatorProjectsAllPolicyRule',
          value  => [$group_a->{phid}, $group_b->{phid}],
        },
      ],
    },
    'policy.create params'
  );

  my ($query) = $conduit->calls('policy.query');
  ok($policy && $query, 'create reloads the policy');
  is($query->{phids}[0],
    $policy->phid, 'reloaded by the PHID policy.create returned');
  is_deeply(
    [map { $_->phid } @{$policy->rule_projects}],
    [$group_a->{phid}, $group_b->{phid}],
    'created policy has the projects'
  );
}

# create without projects falls back to secure-revision
{
  $conduit->reset_calls;
  my $create_error;
  try { Policy->create([]) } catch { $create_error = $_ };
  is_deeply(
    [map { $_->{constraints} } $conduit->calls('project.search')],
    [{name => 'secure-revision'}],
    'secure-revision project looked up'
  );
  my ($create) = $conduit->calls('policy.create');
  my $fallback = $create->{policy}[-1];
  is($fallback->{action}, 'allow', 'fallback rule is an allow rule');
  is_deeply([ref $fallback->{value} ? @{$fallback->{value}} : $fallback->{value}],
    [$secure->{phid}], 'fallback rule names the secure-revision project');
TODO: {
    local $TODO = 'Policy::create sends the fallback rule without a `rule` key, '
      . 'which the real policy.create rejects as an invalid rule class';
    ok(!$create_error, 'create without projects succeeds');
    is_deeply(
      $fallback,
      {
        action => 'allow',
        rule   => 'PhabricatorProjectsAllPolicyRule',
        value  => [$secure->{phid}],
      },
      'fallback rule has the same shape as the other project rules'
    );
  }
}

# Errors propagate
{
  my $project = Project->new_from_query({phids => [$group_a->{phid}]});
  $conduit->queue(
    'policy.create' => conduit_error('ERR-CONDUIT-CORE', 'Invalid rule'));
  throws_error(
    sub { Policy->create([$project]) },
    'bugzilla.code.phabricator_api_error',
    'policy.create error propagates'
  );

  $conduit->queue('policy.query' => http_error(502));
  throws_error(
    sub { Policy->new_from_query({phids => [$existing->{phid}]}) },
    'bugzilla.code.phabricator_api_error',
    'policy.query error propagates'
  );

  ok(dies { Policy->create(['not a project']) },
    'create requires Project objects');
}

$env->finish;
done_testing;
