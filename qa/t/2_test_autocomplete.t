# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# The user and product/component autocomplete fields must not show their
# suggestion list if the input has lost focus by the time the lookup returns.
# devbridge-autocomplete 2.x calls onSearchComplete before rendering the
# suggestions, so the "hide if unfocused" check in searchComplete has to run
# after the render (bug 2079453).

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Test::More "no_plan";

use QA::Util;

# Replace Bugzilla.API.get with a stub that holds each lookup open until the
# test calls window.__bzLookup.release(), so the field can be blurred while a
# request is still pending.
use constant STUB_LOOKUP_JS => <<'END';
window.__bzLookup = { calls: 0, release: null };
Bugzilla.API.get = (endpoint) => {
  window.__bzLookup.calls++;
  const body = endpoint.startsWith('user/suggest')
    ? { users: [{ name: 'selenium@example.com', real_name: 'Selenium', requests: {}, gravatar: '' }] }
    : { products: [{ product: 'Selenium', component: '' }] };
  return new Promise(resolve => { window.__bzLookup.release = () => resolve(body); });
};
END

use constant SUGGESTIONS_VISIBLE_JS =>
  'return jQuery(".autocomplete-suggestions:visible").length';

my ($sel, $config) = get_selenium();

log_in($sel, $config, 'unprivileged');

# User autocomplete (js/field.js) on the advanced search page.
go_to_home($sel);
open_advanced_search_page($sel);
check_autocomplete($sel, 'email1', 'sel', 'user autocomplete', 1);

go_to_home($sel);
open_advanced_search_page($sel);
check_autocomplete($sel, 'email1', 'sel', 'user autocomplete', 0);

# Product/component search (extensions/ProdCompSearch).
$sel->open_ok('/page.cgi?id=prodcompsearch.html');
$sel->wait_for_page_to_load_ok(WAIT_TIME);
check_autocomplete($sel, 'pcs', 'sel',
  'product/component search', 1);

$sel->open_ok('/page.cgi?id=prodcompsearch.html');
$sel->wait_for_page_to_load_ok(WAIT_TIME);
check_autocomplete($sel, 'pcs', 'sel',
  'product/component search', 0);

logout($sel);

# Type into $field and let the stubbed lookup return. With $focused the
# suggestions must be shown; otherwise the field is blurred while the lookup
# is pending and the suggestions must stay hidden.
sub check_autocomplete {
  my ($sel, $field, $text, $desc, $focused) = @_;
  my $driver = $sel->driver;

  $driver->execute_script(STUB_LOOKUP_JS);
  $sel->type_ok($field, $text, "Type into the $desc field");

  ok(wait_for_js($sel, 'return window.__bzLookup.calls'),
    "$desc lookup started");

  if (!$focused) {
    $driver->execute_script("document.getElementById('$field').blur()");

    # Let the widget's own 200ms blur timeout run first, as it would for a
    # slow request in the real app.
    select(undef, undef, undef, 0.5);
  }

  $driver->execute_script('window.__bzLookup.release?.()');

  if ($focused) {
    ok(wait_for_js($sel, SUGGESTIONS_VISIBLE_JS),
      "$desc suggestions are shown while the field has focus");
  }
  else {
    select(undef, undef, undef, 0.5);
    ok(!$driver->execute_script(SUGGESTIONS_VISIBLE_JS),
      "$desc suggestions stay hidden after the field loses focus");
  }
}

# Poll a script returning a true value for up to 5 seconds.
sub wait_for_js {
  my ($sel, $script) = @_;
  my $result;
  for (0 .. 50) {
    $result = $sel->driver->execute_script($script);
    last if $result;
    select(undef, undef, undef, 0.1);
  }
  return $result;
}
