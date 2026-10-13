#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.attachments()           #
# GET /rest/bug/<id>/attachment                       #
# GET /rest/bug/attachment/<attachment_id>            #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Bugzilla::Attachment;
use Bugzilla::User;
use Data::Dumper;
use List::Util qw(first);
use MIME::Base64 qw(decode_base64 encode_base64);
use QA::Util qw(get_config);
use QA::Tests qw(STANDARD_BUG_TESTS PRIVATE_BUG_USER);
use QA::REST::Util qw(api_headers);

use Test::Mojo;
use Test::More;

# REST returns dates in ISO-8601 (with a trailing Z).
use constant DATETIME_REGEX => qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ?$/;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

################
# Bug ID Tests #
################

my %attachments;

foreach my $test (@{STANDARD_BUG_TESTS()}) {
  my $id = $test->{args}{ids}[0];
  next if !defined $id;

  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $path    = $url . "rest/bug/$id/attachment";

  if (my $error = $test->{error}) {
    $t->get_ok($path => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
    next;
  }

  $t->get_ok($path => $headers)->status_is(200);
  my $bugs = $t->tx->res->json->{bugs};
  is(scalar keys %$bugs, 1, "Got exactly one bug") or diag(Dumper($bugs));
  my $bug_attachments = (values %$bugs)[0];

  foreach my $alias (qw(public_bug private_bug)) {
    foreach my $is_private (0, 1) {
      my $find_desc = "${alias}_${is_private}";
      my $attachment = first { $_->{summary} eq $find_desc }
      reverse @$bug_attachments;
      if ($attachment) {
        $attachments{$find_desc} = $attachment->{id};
      }
    }
  }
}

foreach my $alias (qw(public_bug private_bug)) {
  foreach my $is_private (0, 1) {
    ok(
      $attachments{"${alias}_${is_private}"},
      "Found attachment id for ${alias}_${is_private}"
    );
  }
}

####################
# Attachment Tests #
####################

my $content_file = '../config/generate_test_data.pl';
open(my $fh, '<', $content_file) or die "$content_file: $!";
my $content;
{ local $/; $content = <$fh>; }
close($fh);

my @tests = (

  # Logged-out user
  {
    args => {attachment_ids => [$attachments{'public_bug_0'}]},
    test => 'Logged-out user can access public attachment on public bug by id',
  },
  {
    args  => {attachment_ids => [$attachments{'public_bug_1'}]},
    test  => 'Logged-out user cannot access private attachment on public bug',
    error => 'Sorry, you are not authorized',
  },
  {
    args  => {attachment_ids => [$attachments{'private_bug_0'}]},
    test  => 'Logged-out user cannot access attachments by id on private bug',
    error => 'You are not authorized to access',
  },
  {
    args => {attachment_ids => [$attachments{'private_bug_1'}]},
    test => 'Logged-out user cannot access private attachment on private bug',
    error => 'You are not authorized to access',
  },

  # Logged-in, unprivileged user.
  {
    user => 'unprivileged',
    args => {attachment_ids => [$attachments{'public_bug_0'}]},
    test => 'Logged-in user can see a public attachment on a public bug by id',
  },
  {
    user  => 'unprivileged',
    args  => {attachment_ids => [$attachments{'public_bug_1'}]},
    test  => 'Logged-in user cannot access private attachment on public bug',
    error => 'Sorry, you are not authorized',
  },
  {
    user  => 'unprivileged',
    args  => {attachment_ids => [$attachments{'private_bug_0'}]},
    test  => 'Logged-in user cannot access attachments by id on private bug',
    error => "You are not authorized to access",
  },
  {
    user  => 'unprivileged',
    args  => {attachment_ids => [$attachments{'private_bug_1'}]},
    test  => 'Logged-in user cannot access private attachment on private bug',
    error => "You are not authorized to access",
  },

  # User who can see private bugs and private attachments
  {
    user => PRIVATE_BUG_USER,
    args => {attachment_ids => [$attachments{'public_bug_1'}]},
    test => PRIVATE_BUG_USER . ' can see private attachment on public bug',
  },
  {
    user => PRIVATE_BUG_USER,
    args => {attachment_ids => [$attachments{'private_bug_1'}]},
    test => PRIVATE_BUG_USER . ' can see private attachment on private bug',
  },
);

foreach my $test (@tests) {
  my $aid     = $test->{args}{attachment_ids}[0];
  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $path    = $url . "rest/bug/attachment/$aid";

  if (my $error = $test->{error}) {
    $t->get_ok($path => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
    next;
  }

  $t->get_ok($path => $headers)->status_is(200);
  my $all = $t->tx->res->json->{attachments};
  is(scalar keys %$all, 1, "Got exactly one attachment");
  my $attachment = (values %$all)[0];

  like($attachment->{last_change_time}, DATETIME_REGEX,
    "last_change_time is in the right format");
  like($attachment->{creation_time}, DATETIME_REGEX,
    "creation_time is in the right format");
  is($attachment->{is_obsolete}, 0, 'is_obsolete is 0');
  like($attachment->{bug_id}, qr/^\d+$/, "bug_id is an integer");
  like($attachment->{id},     qr/^\d+$/, "id is an integer");
  is($attachment->{content_type}, 'application/x-perl', "content_type is correct");
  like($attachment->{file_name}, qr/^\w+\.pl$/, "filename is in the expected format");
  is($attachment->{creator}, $config->{QA_Selenium_TEST_user_login},
    "creator is the correct user");
  my $data = decode_base64($attachment->{data});
  is($data,               $content,      'data is correct');
  is($attachment->{size}, length($data), "size matches data's size");
}
#############################
# Deleted Attachment Tests  #
#############################

# Deleting an attachment through the web UI zeroes attach_size and removes
# the stored object, so asking for its data must not fail the request that
# happens to include it.

my $admin_headers = api_headers($config->{admin_user_api_key});

$t->post_ok(
  $url
    . 'rest/bug' => $admin_headers => json => {
    product     => 'Firefox',
    component   => 'General',
    summary     => 'Test bug for deleted attachment data',
    type        => 'defect',
    version     => 'unspecified',
    severity    => 'normal',
    description => 'This bug exists to test deleted attachment data.',
    }
)->status_is(200)->json_has('/id');
my $deleted_bug_id = $t->tx->res->json->{id};
ok($deleted_bug_id, "Created bug $deleted_bug_id to hold a deleted attachment");

$t->post_ok(
  $url
    . "rest/bug/$deleted_bug_id/attachment" => $admin_headers => json => {
    summary      => 'attachment to be deleted',
    content_type => 'text/plain',
    data         => encode_base64('this data will be removed'),
    file_name    => 'to-be-deleted.txt',
    is_patch     => 0,
    is_private   => 0,
    }
)->status_is(201);
my ($deleted_att_id) = keys %{$t->tx->res->json->{attachments}};
ok($deleted_att_id, "Created attachment $deleted_att_id");

# Remove the data the same way attachment.cgi's delete action does.
Bugzilla->set_user(Bugzilla::User->check($config->{admin_user_login}));
Bugzilla::Attachment->new($deleted_att_id)->remove_from_db();

$t->get_ok($url . "rest/bug/attachment/$deleted_att_id" => $admin_headers)
  ->status_is(200, 'Deleted attachment is still fetchable by id');
my $deleted_att = $t->tx->res->json->{attachments}->{$deleted_att_id};
is($deleted_att->{data}, '', 'Deleted attachment data is an empty string');
is($deleted_att->{size}, 0,  'Deleted attachment size is 0');

# The original failure: include_fields=_all on a bug carrying a deleted
# attachment threw net_storage_get_failed and lost the whole response.
$t->get_ok(
  $url . "rest/bug/$deleted_bug_id?include_fields=_all" => $admin_headers)
  ->status_is(200, 'include_fields=_all succeeds with a deleted attachment');
my $all_bug = $t->tx->res->json->{bugs}->[0];
my $all_att = first { $_->{id} == $deleted_att_id } @{$all_bug->{attachments}};
ok($all_att, 'Deleted attachment is still listed under include_fields=_all');
is($all_att->{data}, '', 'Deleted attachment data is empty under _all');
is($all_att->{size}, 0,  'Deleted attachment size is 0 under _all');

done_testing();
