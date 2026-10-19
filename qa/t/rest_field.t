#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#####################################################
# Test for REST call to Bug.fields()                #
# GET /rest/field/bug                                #
#####################################################

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use List::Util qw(first);
use QA::Util qw(get_config);
use QA::REST::Util qw(api_headers rest_get_url);

use Test::Mojo;
use Test::More;

my $config = get_config();
my $url     = Bugzilla->localconfig->urlbase;

use constant INVALID_FIELD_NAME => 'invalid_field';
use constant INVALID_FIELD_ID   => -1;

sub GLOBAL_GENERAL_FIELDS {
  my @fields = qw(
    attach_data.thedata
    attachments.description attachments.filename attachments.isobsolete
    attachments.ispatch attachments.isprivate attachments.mimetype
    attachments.submitter
    flagtypes.name requestees.login_name setters.login_name
    alias assigned_to blocked bug_file_loc bug_group bug_id cc
    cclist_accessible classification commenter content creation_ts
    days_elapsed delta_ts dependson everconfirmed keywords longdesc
    longdescs.isprivate owner_idle_time product qa_contact regressed_by
    regresses reporter reporter_accessible see_also short_desc
    status_whiteboard deadline estimated_time percentage_complete
    remaining_time work_time
  );
  push(@fields, 'votes') if $config->{test_extensions};
  return @fields;
}

use constant STANDARD_SELECT_FIELDS =>
  qw(bug_type bug_severity bug_status op_sys priority rep_platform resolution);
use constant ALL_SELECT_FIELDS =>
  (STANDARD_SELECT_FIELDS, qw(cf_qa_status cf_single_select));
use constant PRODUCT_FIELDS => qw(version target_milestone component);
sub ALL_FIELDS { (GLOBAL_GENERAL_FIELDS(), ALL_SELECT_FIELDS, PRODUCT_FIELDS) }
use constant MANDATORY_FIELDS => qw(short_desc product component);

use constant PUBLIC_PRODUCT  => 'Another Product';
use constant PRIVATE_PRODUCT => 'QA-Selenium-TEST';

sub get_field {
  my ($fields, $field) = @_;
  return first { $_->{name} eq $field } @$fields;
}

sub get_products_from_field {
  my $field = shift;
  my %products;
  foreach my $value (@{$field->{values}}) {
    foreach my $vis_value (@{$value->{visibility_values}}) {
      $products{$vis_value} = 1;
    }
  }
  return \%products;
}

my @ALL_FIELDS     = ALL_FIELDS();
my @PRODUCT_FIELDS = PRODUCT_FIELDS;

my $t = Test::Mojo->new();
$t->ua->max_redirects(1);

# Fetch all fields (anonymously) and validate their structure.
$t->get_ok($url . 'rest/field/bug' => api_headers(undef))->status_is(200);
my $fields = $t->tx->res->json->{fields};

my %field_ids;
foreach my $field (@ALL_FIELDS) {
  my $field_data = get_field($fields, $field);
  ok($field_data, "$field is in the returned result");
  $field_ids{$field} = $field_data->{id};

  if (grep($_ eq $field, MANDATORY_FIELDS)) {
    ok($field_data->{is_mandatory}, "$field is mandatory");
  }
  else {
    ok(!$field_data->{is_mandatory}, "$field is not mandatory");
  }
}

foreach my $field (ALL_SELECT_FIELDS, PRODUCT_FIELDS) {
  my $field_data = get_field($fields, $field);
  ok(defined $field_data->{visibility_values}, "$field has visibility_values defined");
  my $field_vis_undefs = grep { !defined $_ } @{$field_data->{visibility_values}};
  is($field_vis_undefs, 0, "$field.visibility_values has no undefs");

  ok(defined $field_data->{values}, "$field has 'values' defined");
  my $num_values = scalar @{$field_data->{values}};
  ok($num_values, "$field has $num_values values");

  # The first bug status is a fake one and has no name, so we use the 2nd item.
  my $first_value = $field_data->{values}[1];
  ok(defined $first_value->{name}, 'The first value has a name');
  like($first_value->{sortkey}, qr/^-?\d+$/, "The first value has a numeric sortkey");
  ok(defined $first_value->{visibility_values},
    "$field has visibility_values defined on its first value");
  my @value_visibility_values
    = map { @{$_->{visibility_values}} } @{$field_data->{values}};
  my $undefs = grep { !defined $_ } @value_visibility_values;
  is($undefs, 0, "$field.values.visibility_values has no undefs");
}

foreach my $field (PRODUCT_FIELDS) {
  my $field_data = get_field($fields, $field);
  is($field_data->{value_field}, 'product', "The value_field for $field is 'product'");
  my $products = get_products_from_field($field_data);
  ok($products->{+PUBLIC_PRODUCT}, "$field values are returned for the public product");
  ok(!$products->{+PRIVATE_PRODUCT},
    "No $field values are returned for the private product");
}

# Table-driven tests against Bug.fields with ids/names arguments.
my @all_tests = (
  {
    args  => {ids => [values %field_ids], names => [@ALL_FIELDS]},
    test  => 'Getting all fields by name and id simultaneously',
    count => scalar(@ALL_FIELDS),
  },
  {
    args  => {names => [INVALID_FIELD_NAME]},
    error => "There is no field named",
    test  => 'Invalid field name'
  },
  {
    args  => {ids => [INVALID_FIELD_ID]},
    error => 'must be numeric',
    test  => 'Invalid field id'
  },
  {
    user  => 'QA_Selenium_TEST',
    args  => {names => [@PRODUCT_FIELDS]},
    test  => 'Getting product-specific fields as a privileged user',
    count => scalar(@PRODUCT_FIELDS),
    product_private_values => 1
  },
);

foreach my $field (@ALL_FIELDS) {
  push(@all_tests,
    {args => {names => [$field]}, test => "Logged-out users can get the $field field by name"});
  push(@all_tests,
    {args => {ids => [$field_ids{$field}]}, test => "Logged-out users can get the $field by id"});
}

foreach my $test (@all_tests) {
  my $api_key = $test->{user} ? $config->{"$test->{user}_user_api_key"} : undef;
  my $headers = api_headers($api_key);
  my $url_obj = rest_get_url($url, 'rest/field/bug', $test->{args});

  if (my $error = $test->{error}) {
    $t->get_ok($url_obj => $headers)->status_isnt(200);
    like($t->tx->res->json->{message}, qr/\Q$error\E/, "$test->{test}: $error");
    next;
  }

  $t->get_ok($url_obj => $headers)->status_is(200);
  my $got   = $t->tx->res->json->{fields};
  my $count = defined $test->{count} ? $test->{count} : 1;
  is(scalar @$got, $count, "$test->{test}: exactly $count field(s) returned");

  if ($test->{product_private_values}) {
    foreach my $field_data (@$got) {
      my $products = get_products_from_field($field_data);
      ok($products->{+PUBLIC_PRODUCT},
        "$field_data->{name} values are returned for the public product");
      ok($products->{+PRIVATE_PRODUCT},
        "$field_data->{name} values are returned for the private product");
    }
  }
}

# A field in the path is combined with the ones from the query string.
$t->get_ok(
  $url . 'rest/field/bug/bug_status?names=priority' => api_headers(undef))
  ->status_is(200);
is_deeply(
  [sort map { $_->{name} } @{$t->tx->res->json->{fields}}],
  ['bug_status', 'priority'],
  'Field names from the path and the query string are combined'
);

$t->get_ok(
  $url . 'rest/field/bug/priority?include_fields=id,name' => api_headers(undef))
  ->status_is(200);
is_deeply(
  [sort keys %{$t->tx->res->json->{fields}[0]}],
  ['id', 'name'],
  'include_fields filters the returned keys'
);

done_testing();
