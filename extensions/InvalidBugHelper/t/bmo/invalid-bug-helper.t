#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Test::More;

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Bug;
use Bugzilla::Component;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::User;

# Load Bugzilla::Extension to install the INC_HOOK that maps
# Bugzilla::Extension::NAME::* to extensions/NAME/lib/*.
use_ok('Bugzilla::Extension');

# The INC_HOOK maps Bugzilla::Extension::InvalidBugHelper::* to
# extensions/InvalidBugHelper/lib/*.
use_ok('Bugzilla::Extension::InvalidBugHelper::WebService');
use_ok('Bugzilla::Extension::InvalidBugHelper::Config');

# Verify rest_resources returns the expected REST route.
my $resources = Bugzilla::Extension::InvalidBugHelper::WebService->rest_resources;
ok(ref $resources eq 'ARRAY', 'rest_resources returns an arrayref');
ok(scalar(@$resources) == 2, 'rest_resources has two elements (pattern + handler)');

my ($pattern, $handlers) = @$resources;
ok(ref $pattern eq 'Regexp', 'first element is a regex');
ok(exists $handlers->{POST}, 'handler defines a POST method');
ok($handlers->{POST}{method} eq 'close_as_invalid',
  'POST handler maps to close_as_invalid');

# Verify the route regex matches valid bug IDs and rejects invalid ones.
ok('/invalid_bug_helper/close/123' =~ $pattern, 'route matches numeric bug id');
ok('/invalid_bug_helper/close/0' =~ $pattern,   'route matches bug id 0');
ok('/invalid_bug_helper/close/abc' !~ $pattern,  'route rejects non-numeric id');
ok('/invalid_bug_helper/close/' !~ $pattern,     'route rejects missing id');

# Verify the params sub extracts bug_id from the capture group.
my $params_sub = $handlers->{POST}{params};
is(ref $params_sub, 'CODE', 'params is a code ref');
is_deeply($params_sub->(42), {bug_id => 42}, 'params sub extracts bug_id');

# Verify PUBLIC_METHODS includes close_as_invalid.
my @public = Bugzilla::Extension::InvalidBugHelper::WebService->PUBLIC_METHODS;
ok(grep({ $_ eq 'close_as_invalid' } @public),
  'close_as_invalid is in PUBLIC_METHODS');

# Verify Config returns the expected params.
my @params = Bugzilla::Extension::InvalidBugHelper::Config->get_param_list;
my %param_names = map { $_->{name} => 1 } @params;
ok($param_names{invalidbughelper_warning_text}, 'warning_text param defined');

# Verify close_as_invalid refuses to act on bugs reported by an editbugs
# member, regardless of who is performing the close (Bug 1684509).

BEGIN { Bugzilla->extensions }
Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $product = Bugzilla::Product->new({name => 'Firefox'})
  || (Bugzilla::Product->get_all)[0];
my $editbugs_group = Bugzilla::Group->new({name => 'editbugs'});

plan skip_all => 'Need a product and the editbugs group to test close_as_invalid'
  unless $product && $editbugs_group;

my $dbh = Bugzilla->dbh;
my $admin = Bugzilla::User->new({name => 'admin@mozilla.bugs'});
plan skip_all => 'Need an editbugs admin user to test close_as_invalid'
  unless $admin && $admin->in_group('editbugs');

sub make_reporter {
  my ($in_editbugs) = @_;
  my $user = Bugzilla::User->create({
    login_name => 'invalid-bug-helper-test-' . $$ . '-' . (0 + rand(100000)) . '@bmo.tld',
    cryptpassword => '*',
  });
  $dbh->do(
    'INSERT INTO user_group_map (user_id, group_id, isbless, grant_type) VALUES (?, ?, 0, ?)',
    undef, $user->id, $editbugs_group->id, GRANT_DIRECT)
    if $in_editbugs;
  return Bugzilla::User->new($user->id);
}

sub make_bug_as {
  my ($reporter) = @_;
  Bugzilla->set_user($reporter);
  return Bugzilla::Bug->create({
    short_desc   => 'Invalid bug helper reporter test ' . $$,
    product      => $product->name,
    component    => $product->components->[0]->name,
    bug_type     => 'defect',
    bug_severity => 'normal',
    op_sys       => 'Unspecified',
    rep_platform => 'Unspecified',
    version      => $product->versions->[0]->name,
  });
}

my $editbugs_reporter = make_reporter(1);
my $plain_reporter    = make_reporter(0);

my $bug_from_editbugs_reporter = make_bug_as($editbugs_reporter);
my $bug_from_plain_reporter    = make_bug_as($plain_reporter);

Bugzilla->set_user($admin);

my $ws = 'Bugzilla::Extension::InvalidBugHelper::WebService';

eval { $ws->close_as_invalid({bug_id => $bug_from_editbugs_reporter->id}) };
like($@, qr/reported by a member of the 'editbugs' group/,
  'close_as_invalid refuses a bug reported by an editbugs member');

# The real return-value serialization (->type) is only provided by the
# JSON-RPC/REST server at dispatch time; stub it here so we can exercise
# close_as_invalid's business logic directly.
no strict 'refs';
no warnings 'redefine';
local *{"${ws}::type"} = sub { return $_[2] };
use strict 'refs';

# The test data has no Invalid Bugs product, the one close_as_invalid moves
# bugs to. It needs the version and milestone of the bug it receives.
if (!Bugzilla::Product->new({name => 'Invalid Bugs'})) {
  my $invalid = Bugzilla::Product->create({
    name            => 'Invalid Bugs',
    description     => 'Bugs closed by the invalid bug helper',
    default_version => $bug_from_plain_reporter->version,
  });
  Bugzilla::Component->create({
    name         => 'General',
    product      => $invalid,
    description  => 'Invalid bugs',
    initialowner => $admin->login,
    team_name    => 'Mozilla',
  });

  # The user caches the products it can enter.
  Bugzilla->set_user(Bugzilla::User->new($admin->id));
}

SKIP: {
  skip 'Need the Invalid Bugs product to test the non-editbugs-reporter path', 3
    unless Bugzilla::Product->new({name => 'Invalid Bugs'});

  # Flag mail is part of bugmail, so closing must send it.
  my @sent;
  local *Bugzilla::BugMail::Send = sub { push @sent, $_[0] };

  my $result = eval { $ws->close_as_invalid({bug_id => $bug_from_plain_reporter->id}) };
  is($@, '', 'close_as_invalid does not throw for a bug reported by a non-editbugs user');
  is_deeply(\@sent, [$bug_from_plain_reporter->id], 'and sends the bugmail');
  is(ref $result eq 'HASH' ? $result->{product} : undef, 'Invalid Bugs',
    'bug from non-editbugs reporter is moved to Invalid Bugs');
}

done_testing();
