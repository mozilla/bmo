#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Users without editbugs must not be able to choose severity or priority when
# filing a bug, whichever entry path they use (REST API, post_bug.cgi). The
# values are silently reset to the configured defaults. Users without
# canconfirm likewise cannot add keywords when filing, nor change them later.
# Triagers (can_triage_bugs) may set severity and priority without editbugs,
# as triaging a defect needs an S* severity. Trusted server-side creates keep
# their values (Bug 2078325).

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Bug;
use Bugzilla::Field::Choice;
use Bugzilla::Keyword;
use Bugzilla::Product;
use Bugzilla::User;
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $default_sev = Bugzilla->params->{defaultseverity};
my $default_pri = Bugzilla->params->{defaultpriority};

# Pick legal values that differ from the defaults so a reset is observable.
# Skip S1: Post::SeverityS1PriorityP1 rewrites the priority of S1 bugs.
sub non_default_value {
  my ($field, $default) = @_;
  my ($choice)
    = grep { $_->is_active && $_->name ne $default && $_->name ne 'S1' }
    Bugzilla::Field::Choice->type($field)->get_all;
  return $choice ? $choice->name : undef;
}
my $wanted_sev = non_default_value('bug_severity', $default_sev);
my $wanted_pri = non_default_value('priority',     $default_pri);
plan skip_all => 'Need a non-default severity and priority'
  unless $wanted_sev && $wanted_pri;

my ($keyword) = grep { $_->name ne 'triaged' } Bugzilla::Keyword->get_all;
plan skip_all => 'Need a keyword other than triaged' unless $keyword;

my $admin = Bugzilla::User->check({id => 1});
Bugzilla->set_user($admin);

my ($product)
  = grep { @{$_->components} && @{$_->versions} } Bugzilla::Product->get_all;
plan skip_all => 'Need a product with a component and a version'
  unless $product;

my $reporter = Bugzilla::User->create({
  login_name    => "create-restricted-$$\@example.com",
  realname      => 'Restricted Reporter',
  cryptpassword => '*',
});
ok(
  !$reporter->in_group('editbugs', $product->id),
  'Test reporter does not have editbugs'
);

# A triager with canconfirm but no editbugs: can_triage_bugs is a standalone
# group, so this combination exists.
my $triager = Bugzilla::User->create({
  login_name    => "create-restricted-triager-$$\@example.com",
  realname      => 'Triager Without Editbugs',
  cryptpassword => '*',
});
$triager->set_groups({add => ['can_triage_bugs', 'canconfirm']});
$triager->update();
$triager = Bugzilla::User->new({id => $triager->id});
ok($triager->can_triage, 'Test triager can triage');
ok(
  !$triager->in_group('editbugs', $product->id),
  'Test triager does not have editbugs'
);

sub file_bug {
  my ($user, %opts) = @_;
  Bugzilla->set_user($user);
  local Bugzilla->request_cache->{mozchangefield_trusted_create} = 1
    if $opts{trusted};
  my $bug = Bugzilla::Bug->create({
    short_desc   => "Restricted field test - $$",
    product      => $product->name,
    component    => $product->components->[0]->name,
    version      => $product->versions->[0]->name,
    bug_type     => 'defect',
    op_sys       => 'Unspecified',
    rep_platform => 'Unspecified',
    bug_severity => $wanted_sev,
    priority     => $wanted_pri,
    keywords     => [$keyword->name],
    comment      => 'test',
  });
  return Bugzilla::Bug->new($bug->id);
}

{
  my $bug = file_bug($reporter);
  is($bug->bug_severity, $default_sev,
    'Severity reset to default for a reporter without editbugs');
  is($bug->priority, $default_pri,
    'Priority reset to default for a reporter without editbugs');
  is($bug->bug_type, 'defect', 'Reporter can still choose the bug type');
  ok(!$bug->has_keyword($keyword->name),
    'Keywords dropped for a reporter without canconfirm');

  # Core lets the reporter edit keywords; MozChangeField must not.
  Bugzilla->set_user($reporter);
  ok(!eval { $bug->modify_keywords($keyword->name, 'add'); 1 },
    'Reporter without canconfirm cannot add keywords afterwards');
}

{
  my $bug = file_bug($admin);
  is($bug->bug_severity, $wanted_sev, 'Severity kept for an editbugs user');
  is($bug->priority,     $wanted_pri, 'Priority kept for an editbugs user');
  ok($bug->has_keyword($keyword->name), 'Keywords kept for an editbugs user');
}

{
  my $bug = file_bug($triager);
  is($bug->bug_severity, $wanted_sev, 'Severity kept for a triager');
  is($bug->priority,     $wanted_pri, 'Priority kept for a triager');
  ok($bug->has_keyword($keyword->name), 'Keywords kept for a triager');

  Bugzilla->set_user($triager);
  ok(eval { $bug->set_severity($default_sev); 1 },
    'Triager can change severity afterwards')
    or diag $@;
  ok(!eval { $bug->set_type('task'); 1 },
    'Triager without editbugs still cannot change the bug type');
}

{
  my $bug = file_bug($reporter, trusted => 1);
  is($bug->bug_severity, $wanted_sev, 'Severity kept for a trusted create');
  is($bug->priority,     $wanted_pri, 'Priority kept for a trusted create');
  ok($bug->has_keyword($keyword->name), 'Keywords kept for a trusted create');
}

done_testing;
