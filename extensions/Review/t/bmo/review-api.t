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

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

my $admin = Bugzilla::User->new({name => 'admin@mozilla.bugs'});
my ($product) = grep {
       $_->is_active
    && @{$_->components}
    && @{$_->versions}
    && $_->default_security_group
} Bugzilla::Product->get_all;
plan skip_all => 'Need an admin and a product with a security group'
  unless $admin && $product;

my ($mentor, $requestee) = map {
  Bugzilla::User->create({
    login_name => "review-api-$_-$$\@bmo.tld", cryptpassword => '*',
  })
} qw(mentor requestee);
my %auth = ('X-Bugzilla-API-Key' => issue_api_key($admin->login)->api_key);
my $t    = Test::Mojo->new('Bugzilla::App');

Bugzilla->set_user($admin);
my %fields = (
  product      => $product->name,
  component    => $product->components->[0]->name,
  bug_type     => 'defect',
  bug_severity => 'normal',
  op_sys       => 'Unspecified',
  rep_platform => 'Unspecified',
  version      => $product->versions->[0]->name,
  comment      => 'a comment',
);
my $bug = Bugzilla::Bug->create({
  %fields,
  short_desc  => "Review API test $$",
  bug_mentors => [$mentor->login],
});
# The requestee is on the CC list, so the needinfo below can be set on it.
my $private = Bugzilla::Bug->create({
  %fields,
  short_desc        => "Review API private $$",
  groups            => [$product->default_security_group],
  cc                => [$requestee->login],
  cclist_accessible => 1,
});

# A needinfo request on each bug, so they have flag activity.
my $flagged = eval {
  for my $b ($bug, $private) {
    my ($flags, $new_flags)
      = extract_flags(
      [{name => 'needinfo', status => '?', requestee => $requestee->login}], $b);
    $b->set_flags($flags, $new_flags);
    $b->update;
  }
  1;
};
Bugzilla->clear_request_cache;

# suggestions
$t->get_ok('/rest/review/suggestions/' . $bug->id => \%auth)
  ->status_is(200)
  ->json_is('/0/email' => $mentor->login)
  ->json_is('/0/id'    => $mentor->id, 'mentor suggested, id is a number');
$t->get_ok('/rest/review/suggestions?bug_id=' . $bug->id)
  ->status_is(200)
  ->json_is('/0/id' => $mentor->id, 'bug_id as a query param, signed out');
$t->get_ok('/rest/review/suggestions/' . $product->name)
  ->status_is(200)
  ->json_has('', 'by product');
$t->get_ok('/rest/review/suggestions/'
    . $product->name . '/'
    . $product->components->[0]->name)
  ->status_is(200)
  ->json_has('', 'by product and component');
$t->get_ok('/rest/review/suggestions/No.Such%20Product')
  ->json_is('/error' => 1)
  ->json_like('/message' => qr/No\.Such Product/, 'unknown product');
$t->get_ok('/rest/review/suggestions')
  ->json_is('/error' => 1)
  ->json_like('/message' => qr/must provide either a bug_id/, 'no params');

# flag_activity
SKIP: {
  skip 'no needinfo flag type', 21 unless $flagged;
  my $login = $requestee->login;

  $t->get_ok("/rest/review/flag_activity/requestee/$login" => \%auth)
    ->status_is(200)
    ->json_is('/0/requestee/name' => $login)
    ->json_is('/0/type/name'      => 'needinfo')
    ->json_is('/0/type/is_active' => Mojo::JSON::true, 'by requestee');
  my ($activity) = grep { $_->{bug_id} == $bug->id } @{$t->tx->res->json};
  ok($activity, 'the public bug is listed');
  my $flag_id = $activity->{flag_id};

  $t->get_ok("/rest/review/flag_activity/requestee/$login")
    ->status_is(200)
    ->json_is('/0/bug_id' => $bug->id)
    ->json_is('/1'        => undef, 'the private bug is hidden when signed out');

  $t->get_ok("/rest/review/flag_activity/$flag_id" => \%auth)
    ->status_is(200)
    ->json_hasnt('/0/flag_id', 'by flag id, without flag_id');
  $t->get_ok("/rest/review/flag_activity?flag_ids=$flag_id" => \%auth)
    ->json_is('/0/flag_id' => $flag_id, 'flag_ids as a query param');

  $t->get_ok("/rest/review/flag_activity/type_name/needinfo"
      . "?requestee=$login&include_fields=id,status" => \%auth)
    ->json_is('/0/status' => '?')
    ->json_hasnt('/0/type', 'by type name, include_fields as a list');
  $t->get_ok("/rest/review/flag_activity/type_name/needinfo"
      . "?requestee=$login&include_fields=id&include_fields=status" => \%auth)
    ->json_has('/0/id')
    ->json_has('/0/status')
    ->json_hasnt('/0/type', 'include_fields repeated keeps every value');

  # A repeated bug_id or status matches any of the values.
  my ($bid, $pid) = ($bug->id, $private->id);
  $t->get_ok("/rest/review/flag_activity?bug_id=$bid&bug_id=$pid"
      . "&status=X&status=?" => \%auth)->status_is(200);
  is_deeply(
    [sort { $a <=> $b } map { $_->{bug_id} } @{$t->tx->res->json}],
    [$bid, $pid],
    'activity on both bugs'
  );
}
$t->get_ok('/rest/review/flag_activity/requestee/nobody-here@bmo.tld')
  ->json_is('/error' => 1, 'unknown requestee');
$t->get_ok('/rest/review/flag_activity/requestee/')
  ->status_is(200)
  ->json_hasnt('/error', 'an empty requestee is ignored, not a 404');
$t->get_ok('/rest/review/flag_activity?bug_id=1&offset=5')
  ->json_is('/error' => 1, 'offset needs a limit');

done_testing;
