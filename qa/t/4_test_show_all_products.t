# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Test::More "no_plan";

use QA::Util;

my ($sel, $config) = get_selenium();

log_in($sel, $config, 'admin');
set_parameters($sel, {"Bug Fields" => {"useclassification-on" => undef}});

# Do not use file_bug_in_product() because our goal here is not to file
# a bug but to check what is present in the UI, and also to make sure
# that we get exactly the right page with the right information.
#
# The admin is not a member of the "QA‑Selenium‑TEST" group, and so
# cannot see the "QA‑Selenium‑TEST" product.

$sel->click_ok("//a[./span[contains(text(), 'New Bug')]]");
$sel->wait_for_page_to_load_ok(WAIT_TIME);
$sel->title_is("Enter Bug");
$sel->click_ok('//a/span[contains(text(),"Other Products")]',
  undef, "Choose full product list");
$sel->wait_for_page_to_load(WAIT_TIME);
$sel->title_is("Enter Bug");
ok(
  !$sel->is_text_present("QA-Selenium-TEST"),
  "The QA-Selenium-TEST product is not displayed"
);
logout($sel);

# Same steps, but for a member of the "QA‑Selenium‑TEST" group.
# The "QA‑Selenium‑TEST" product must be visible to them.
# The QA_Selenium_TEST user is unprivileged, so they should see the guided bug
# entry form, which renders dynamically.

log_in($sel, $config, 'QA_Selenium_TEST');
$sel->click_ok("//a[./span[contains(text(), 'New Bug')]]");
$sel->wait_for_page_to_load_ok(WAIT_TIME);
$sel->title_is("Enter Bug");
# `$sel->click_ok()` doesn’t work because the target is not an anchor element
$sel->driver->execute_script('
  document.querySelector("li[data-product=\"Other Products\"]").click();
');
$sel->click_ok('//a[@data-product="QA-Selenium-TEST"]',
  undef, "Choose QA-Selenium-TEST product");
$sel->is_text_present_ok("Product: QA-Selenium-TEST");
logout($sel);
