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
use Test::Mojo;

use Bugzilla;
BEGIN { Bugzilla->extensions }
use Bugzilla::Constants;
use Bugzilla::Bug;
use Bugzilla::Component;
use Bugzilla::Group;
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::Test::Util qw(issue_api_key);

use_ok('Bugzilla::Extension::InvalidBugHelper::Config');

# Verify Config returns the expected params.
my @params = Bugzilla::Extension::InvalidBugHelper::Config->get_param_list;
my %param_names = map { $_->{name} => 1 } @params;
ok($param_names{invalidbughelper_warning_text}, 'warning_text param defined');

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

# POST /rest/invalid_bug_helper/close/<id> is a native Mojo route.
my $api_key = issue_api_key($admin->login)->api_key;
my %auth    = ('X-Bugzilla-API-Key' => $api_key);
my $t       = Test::Mojo->new('Bugzilla::App');

my $close_url = '/rest/invalid_bug_helper/close/';

$t->post_ok($close_url . $bug_from_plain_reporter->id)
  ->status_is(401)
  ->json_is('/code' => 410, 'anonymous request needs a login');

$t->post_ok($close_url
    . $bug_from_plain_reporter->id => \%auth => json => {mark_as_spam => 'maybe'})
  ->status_is(400)
  ->json_like(
  '/message' => qr/mark_as_spam must be true or false/,
  'mark_as_spam must be a boolean'
  );

$t->post_ok($close_url . $bug_from_editbugs_reporter->id => \%auth)
  ->status_isnt(200)
  ->json_like(
  '/message' => qr/reported by a member of the 'editbugs' group/,
  'refuses a bug reported by an editbugs member (bug 1684509)'
  );

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
  skip 'Need the Invalid Bugs product to test the non-editbugs-reporter path', 6
    unless Bugzilla::Product->new({name => 'Invalid Bugs'});

  # Flag mail is part of bugmail, so closing must send it.
  my @sent;
  local *Bugzilla::BugMail::Send = sub { push @sent, $_[0] };

  $t->post_ok($close_url
      . $bug_from_plain_reporter->id => \%auth => json => {mark_as_spam => 0})
    ->status_is(200)
    ->json_is('/id' => $bug_from_plain_reporter->id)
    ->json_is(
    '/product' => 'Invalid Bugs',
    'bug from non-editbugs reporter is moved to Invalid Bugs'
    )->json_is('/status' => 'RESOLVED');
  is_deeply(\@sent, [$bug_from_plain_reporter->id], 'and sends the bugmail');
}

done_testing();
