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
use Bugzilla::Product;
use Bugzilla::User;
use Bugzilla::API::V1::Util qw(extract_flags);
use Bugzilla::Test::Util    qw(issue_api_key);
use Bugzilla::Util          qw(datetime_from);
use Bugzilla::Extension::MyDashboard::BugInterest;

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $admin = Bugzilla::User->new({name => 'admin@mozilla.bugs'});
my $user
  = Bugzilla::User->create({
  login_name => "mydashboard-api-$$\@bmo.tld", cryptpassword => '*',
  });
my ($product)
  = grep { $_->is_active && @{$_->components} && @{$_->versions} }
  Bugzilla::Product->get_all;
plan skip_all => 'Need an admin and a product' unless $admin && $product;

my %auth = ('X-Bugzilla-API-Key' => issue_api_key($user->login)->api_key);
my $t    = Test::Mojo->new('Bugzilla::App');

# A bug assigned to the user, with a needinfo request to them and a comment.
Bugzilla->set_user($admin);
my $bug = Bugzilla::Bug->create({
  short_desc   => "MyDashboard API test $$",
  product      => $product->name,
  component    => $product->components->[0]->name,
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => $product->versions->[0]->name,
  assigned_to  => $user->login,
  comment      => 'first comment',
});
my $flag_set = eval {
  my ($flags, $new_flags)
    = extract_flags(
    [{name => 'needinfo', status => '?', requestee => $user->login}], $bug);
  $bug->set_flags($flags, $new_flags);
  $bug->update;
  1;
};
my $since = $bug->creation_ts;

# Later than the bug's creation, so only this comment is newer than $since.
my $later = datetime_from($since)->add(seconds => 2)->strftime('%Y-%m-%d %T');
$bug->add_comment('a newer comment');
$bug->update($later);

# Login is required.
for my $path (
  qw(run_bug_query?query=assignedbugs run_flag_query?type=requestee
  run_last_changes?bug_id=1)
  )
{
  $t->get_ok("/rest/mydashboard/$path")
    ->status_is(401)
    ->json_is('/error' => 1, "$path needs a login");
}
$t->put_ok('/rest/mydashboard/bug_interest_unmark' => json => {bug_ids => 1})
  ->status_is(401);

# run_bug_query
$t->get_ok('/rest/mydashboard/run_bug_query?query=assignedbugs' => \%auth)
  ->status_is(200)
  ->json_is('/result/name'              => 'assignedbugs')
  ->json_is('/result/bugs/0/bug_id'     => $bug->id, 'bug id is a number')
  ->json_is('/result/bugs/0/short_desc' => $bug->short_desc)
  ->json_has('/result/bugs/0/changeddate_api')
  ->json_like('/result/buffer' => qr/emailassigned_to1=1/, 'query string');
$t->get_ok('/rest/mydashboard/run_bug_query?query=nosuchquery' => \%auth)
  ->status_is(200)
  ->json_is('/result' => undef, 'unknown query');
$t->get_ok('/rest/mydashboard/run_bug_query' => \%auth)
  ->json_is('/error' => 1, 'query is required');

# run_flag_query
SKIP: {
  skip 'no needinfo flag type', 6 unless $flag_set;
  $t->get_ok('/rest/mydashboard/run_flag_query?type=requestee' => \%auth)
    ->status_is(200)
    ->json_is('/result/requestee/0/bug_id'    => $bug->id)
    ->json_is('/result/requestee/0/type'      => 'needinfo')
    ->json_is('/result/requestee/0/is_patch'  => Mojo::JSON::false)
    ->json_is('/result/requestee/0/requester' => $admin->login);
}
$t->get_ok('/rest/mydashboard/run_flag_query' => \%auth)
  ->json_is('/error' => 1, 'type is required');

# run_last_changes
$t->get_ok('/rest/mydashboard/run_last_changes' => \%auth => form =>
    {bug_id => $bug->id, changeddate_api => $since})
  ->status_is(200)
  ->json_like('/results/0/last_changes/comment_html' => qr/a newer comment/)
  ->json_is('/results/0/last_changes/email' => $admin->login)
  ->json_has('/results/0/last_changes/when');
$t->get_ok('/rest/mydashboard/run_last_changes?bug_id=999999999' => \%auth)
  ->json_is('/error' => 1, 'unknown bug');

# bug_interest_unmark, with and without the prefix
my $interest = 'Bugzilla::Extension::MyDashboard::BugInterest';
my $count    = sub {
  scalar @{$interest->match({user_id => $user->id, bug_id => $bug->id})};
};
for my $path ('/rest/mydashboard/bug_interest_unmark',
  '/rest/bug_interest_unmark')
{
  $interest->mark($user->id, $bug->id, $since);
  is($count->(), 1, 'interested in the bug');
  $t->put_ok($path => \%auth => json => {bug_ids => [$bug->id]})
    ->status_is(200)
    ->content_is('0');
  is($count->(), 0, "$path removes the interest");
}
$interest->mark($user->id, $bug->id, $since);
$t->put_ok('/rest/mydashboard/bug_interest_unmark' => \%auth => form =>
    {bug_ids => $bug->id})->status_is(200);
is($count->(), 0, 'one bug ID in the query string');
$t->put_ok('/rest/mydashboard/bug_interest_unmark' => \%auth => json => {})
  ->json_is('/error' => 1, 'bug_ids is required');

done_testing;
