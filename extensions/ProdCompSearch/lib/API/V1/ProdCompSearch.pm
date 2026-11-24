# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::ProdCompSearch::API::V1::ProdCompSearch;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Util qw(detaint_natural trim);
use Bugzilla::API::V1::Util qw(render_options);
use Time::localtime;

sub setup_routes {
  my ($class, $r) = @_;

  # An empty search gets the param_required error, not a 404.
  $r->get('/prod_comp_search/find/*search')
    ->to('ProdCompSearch::API::V1::ProdCompSearch#prod_comp_search',
    search => '');
  $r->get('/prod_comp_search/frequent')
    ->to('ProdCompSearch::API::V1::ProdCompSearch#list_frequent_components');
  $r->options($_)->to(cb => \&render_options, allow => 'GET', search => '')
    foreach qw(/prod_comp_search/find/*search /prod_comp_search/frequent);
}

# GET /prod_comp_search/find/<search>?limit=<n>
#
# Products and components the user can file bugs in matching the words of
# <search> ("product::component" searches each part separately). Returns
# {products => [{product}, {product, component}, ...]}.
sub prod_comp_search {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;
  my $dbh  = Bugzilla->switch_to_shadow_db();

  my $search = trim($self->param('search') // '');
  $search
    || ThrowCodeError('param_required',
    {function => 'PCS.prod_comp_search', param => 'search'});

  my $limit = $self->param('limit');
  $limit = detaint_natural($limit) ? $dbh->sql_limit($limit) : '';

  # We do this in the DB directly as we want it to be fast and
  # not have the overhead of loading full product objects

  # All products which the user has "Entry" access to.
  my $enterable_ids = $dbh->selectcol_arrayref(
    'SELECT products.id FROM products
         LEFT JOIN group_control_map
                   ON group_control_map.product_id = products.id
                      AND group_control_map.entry != 0
                      AND group_id NOT IN (' . $user->groups_as_string . ')
            WHERE group_id IS NULL
                  AND products.isactive = 1'
  );

  if (scalar @$enterable_ids) {

    # And all of these products must have at least one component
    # and one version.
    $enterable_ids = $dbh->selectcol_arrayref(
      'SELECT DISTINCT products.id FROM products
              WHERE '
        . $dbh->sql_in('products.id', $enterable_ids)
        . ' AND products.id IN (SELECT DISTINCT components.product_id
                                      FROM components
                                     WHERE components.isactive = 1)
                AND products.id IN (SELECT DISTINCT versions.product_id
                                      FROM versions
                                     WHERE versions.isactive = 1)'
    );
  }

  return $self->render(json => {products => []}) if !scalar @$enterable_ids;

  my @terms;
  my @order;

  if ($search =~ /^(.*?)::(.*)$/) {
    my ($product, $component) = (trim($1), trim($2));
    push @terms, _build_terms($product,   1, 0);
    push @terms, _build_terms($component, 0, 1);
    push @order, "products.name != " . $dbh->quote($product) if $product ne '';
    push @order, "components.name != " . $dbh->quote($component)
      if $component ne '';
    push @order, _build_like_order($product . ' ' . $component);
    push @order, "products.name";
    push @order, "components.name";
  }
  else {
    push @terms, _build_terms($search, 1, 1);
    push @order, "products.name != " . $dbh->quote($search);
    push @order, "components.name != " . $dbh->quote($search);
    push @order, _build_like_order($search);
    push @order, "products.name";
    push @order, "components.name";
  }
  return $self->render(json => {products => []}) if !scalar @terms;

  # To help Mozilla staff file BMO administration bugs into the right
  # component, sort BMO first when searching for 'bugzilla'
  if (
       $search =~ /bugzilla/i
    && $search !~ /^bugzilla\s*::/i
    && ( $user->in_group('mozilla-corporation')
      || $user->in_group('mozilla-foundation'))
    )
  {
    unshift @order, "products.name != 'bugzilla.mozilla.org'";
  }

  my $components = $dbh->selectall_arrayref("
        SELECT products.name AS product,
               components.name AS component
          FROM products
               INNER JOIN components ON products.id = components.product_id
         WHERE (" . join(" AND ", @terms) . ")
               AND products.id IN (" . join(",", @$enterable_ids) . ")
               AND components.isactive = 1
      ORDER BY " . join(", ", @order) . " $limit", {Slice => {}});

  my $products = [];
  my $current_product;
  foreach my $component (@$components) {
    if (!$current_product || $component->{product} ne $current_product) {
      $current_product = $component->{product};
      push @$products, {product => $current_product};
    }
    push @$products, $component;
  }
  return $self->render(json => {products => $products});
}

# GET /prod_comp_search/frequent
#
# The components the user has reported the most bugs in over the past 2 years,
# at most 10. Returns {results => [{product, component}, ...]}.
sub list_frequent_components {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;

  # Nothing to show if the user is signed out
  return $self->render(json => {results => []}) unless $user->id;

  # Select the date of 2 years ago today
  my $now = localtime;
  my $date = sprintf('%4d-%02d-%02d', $now->year + 1900 - 2, $now->mon + 1, $now->mday);

  my $dbh = Bugzilla->switch_to_shadow_db();
  my $sql = q{
    SELECT count(bugs.bug_id) AS bug_count, products.name AS product, components.name AS component 
      FROM bugs
           INNER JOIN products ON bugs.product_id = products.id
           INNER JOIN components ON bugs.component_id = components.id
     WHERE bugs.reporter = ? AND bugs.creation_ts > ?
           AND products.isactive = 1 AND components.isactive = 1
     GROUP BY products.name, components.name 
     ORDER BY count(bugs.bug_id) DESC LIMIT 10
  };
  my $results = $dbh->selectall_arrayref($sql, {Slice => {}}, $user->id, $date);

  return $self->render(json => {results => $results});
}

###################
# Private Methods #
###################

sub _build_terms {
  my ($query, $product, $component) = @_;
  my $dbh = Bugzilla->dbh();

  my @fields;
  push @fields, 'products.name',   'products.description'   if $product;
  push @fields, 'components.name', 'components.description' if $component;

  # note: CONCAT_WS is MySQL specific
  my $field = "CONCAT_WS(' ', " . join(',', @fields) . ")";

  my @terms;
  foreach my $word (split(/[\s,]+/, $query)) {
    push(@terms, $dbh->sql_iposition($dbh->quote($word), $field) . " > 0")
      if $word ne '';
  }
  return @terms;
}

sub _build_like_order {
  my ($query) = @_;
  my $dbh = Bugzilla->dbh;

  my @terms;
  foreach my $word (split(/[\s,]+/, $query)) {
    push @terms,
      "CONCAT(products.name, components.name) LIKE "
      . $dbh->quote('%' . $word . '%')
      if $word ne '';
  }

  return 'NOT(' . join(' AND ', @terms) . ')';
}

1;
