# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Test::More 'no_plan';

use QA::Util;

# This test exercises the "Show External" button in the bug modal attachments
# list. External attachments are those whose content type is listed in the
# 'attachment_hide_content_types' parameter; they are hidden by default and
# revealed by the "Show External" button. We use GitHub Pull Request URL
# attachments (content type text/x-github-pull-request) as the external type
# because normal users are allowed to create them (unlike Phabricator links).

my ($sel, $config) = get_selenium();

# Return the inline "display" style of an attachment row in the bug modal. The
# updateAttachmentRows() handler in bug_modal.js toggles this directly, so it is
# "none" when the row is hidden and "" (empty) when the row is visible.
sub row_display {
  my ($id) = @_;
  return $sel->driver->execute_script(
    qq{return document.querySelector('#attachments tr[data-attachment-id="$id"]').style.display;}
  );
}

# Look up the id of an attachment from its description link in the modal
# attachments table (works even while the row is hidden).
sub attachment_id_for {
  my ($description) = @_;
  my $href = $sel->get_attribute(
    qq{//table[\@id="attachments"]//a[normalize-space(text())="$description"]\@href});
  my ($id) = $href =~ /id=(\d+)/;
  return $id;
}

# Add a text/URL attachment to the given bug via the create-attachment page.
# When $obsoletes is set, the existing attachment with that id is marked
# obsolete by the new attachment.
sub add_text_attachment {
  my ($bug_id, $content, $description, $obsoletes) = @_;
  $sel->click_ok('attachments-add-link');
  $sel->wait_for_page_to_load_ok(WAIT_TIME);
  $sel->title_is("Create New Attachment for Bug #$bug_id");
  $sel->attach_text($content, 'Enter attachment content');
  $sel->type_ok('att-description', $description, 'Enter attachment description');
  if ($obsoletes) {
    $sel->click_ok(qq{//input[\@name="obsolete" and \@value="$obsoletes"]},
      undef, "Mark attachment $obsoletes obsolete");
  }
  $sel->click_ok('create');
  $sel->wait_for_page_to_load_ok(WAIT_TIME);
  $sel->is_text_present_ok('regexp:Attachment #\d+ to bug \d+ created');
}

my $gh_pr_url_1 = 'https://github.com/mozilla-bteam/bmo/pull/1';
my $gh_pr_url_2 = 'https://github.com/mozilla-bteam/bmo/pull/2';

log_in($sel, $config, 'admin');

# Make sure GitHub Pull Request attachments are treated as external. This is
# the default, but set it explicitly so the test is self-contained.
set_parameters(
  $sel,
  {
    'Attachments' => {
      'attachment_hide_content_types' =>
        {type => 'text', value => 'text/x-github-pull-request'},
    }
  }
);

################################################################################
# Scenario 1: a bug with a normal attachment and a (non-obsolete) external
# attachment. The "Show External" button must appear, the external row must be
# hidden by default, and the button must toggle its visibility.
################################################################################

file_bug_in_product($sel, 'TestProduct');
$sel->type_ok('short_desc', 'External attachments toggle test');
$sel->click_ok('commit');
$sel->wait_for_page_to_load_ok(WAIT_TIME);
$sel->is_text_present_ok('has been added to the database', 'Bug created');
my $bug1_id = $sel->get_value('//input[@name="id" and @type="hidden"]');

go_to_bug($sel, $bug1_id);
add_text_attachment($bug1_id, 'This is a plain text attachment.',
  'plain text attachment s1');
go_to_bug($sel, $bug1_id);
add_text_attachment($bug1_id, $gh_pr_url_1, 'github pr external s1');

go_to_bug($sel, $bug1_id);
my $normal1_id = attachment_id_for('plain text attachment s1');
my $external1_id = attachment_id_for('github pr external s1');
ok($normal1_id,   "Found normal attachment id: $normal1_id");
ok($external1_id, "Found external attachment id: $external1_id");

# The "Show External" button should be rendered, "Show Obsolete" should not
# (there are no obsolete attachments on this bug).
$sel->is_element_present_ok('//button[@id="attachments-external-btn"]',
  undef, 'Show External button is present');
ok(
  !$sel->is_element_present('//button[@id="attachments-obsolete-btn"]'),
  'Show Obsolete button is not present'
);

# By default the normal row is visible and the external row is hidden.
is(row_display($normal1_id), '', 'Normal attachment row is visible by default');
is(row_display($external1_id), 'none',
  'External attachment row is hidden by default');

# Clicking "Show External" reveals the external row and updates the label.
$sel->click_ok('attachments-external-btn');
sleep(1);
is(row_display($external1_id), '',
  'External attachment row is visible after Show External');
is($sel->get_text('//button[@id="attachments-external-btn"]'),
  'Hide External', 'Button label switched to Hide External');

# Clicking again hides it once more.
$sel->click_ok('attachments-external-btn');
sleep(1);
is(row_display($external1_id), 'none',
  'External attachment row is hidden again after Hide External');
is($sel->get_text('//button[@id="attachments-external-btn"]'),
  'Show External', 'Button label switched back to Show External');

################################################################################
# Scenario 2 (regression, bug 2043229): a bug whose only external attachment is
# also obsolete. The "Show External" button must still be rendered so the row is
# reachable, and revealing it requires BOTH "Show External" and "Show Obsolete"
# to be toggled on.
################################################################################

file_bug_in_product($sel, 'TestProduct');
$sel->type_ok('short_desc', 'Obsolete external attachment test');
$sel->click_ok('commit');
$sel->wait_for_page_to_load_ok(WAIT_TIME);
$sel->is_text_present_ok('has been added to the database', 'Bug created');
my $bug2_id = $sel->get_value('//input[@name="id" and @type="hidden"]');

# Add the external attachment first.
go_to_bug($sel, $bug2_id);
add_text_attachment($bug2_id, $gh_pr_url_2, 'github pr obsolete s2');
go_to_bug($sel, $bug2_id);
my $external2_id = attachment_id_for('github pr obsolete s2');
ok($external2_id, "Found external attachment id: $external2_id");

# Add a normal attachment that obsoletes the external one. Now the only external
# attachment on the bug is obsolete.
add_text_attachment($bug2_id, 'This is a plain text attachment.',
  'plain text obsoleter s2', $external2_id);

go_to_bug($sel, $bug2_id);

# Regression check: the "Show External" button must be present even though the
# only external attachment is obsolete (external_attachments_total drives this).
$sel->is_element_present_ok('//button[@id="attachments-external-btn"]',
  undef, 'Show External button is present for obsolete-only external');
$sel->is_element_present_ok('//button[@id="attachments-obsolete-btn"]',
  undef, 'Show Obsolete button is present');

# The obsolete+external row is hidden by default.
is(row_display($external2_id), 'none',
  'Obsolete external row is hidden by default');

# Showing external alone is not enough: the row is also obsolete.
$sel->click_ok('attachments-external-btn');
sleep(1);
is(row_display($external2_id), 'none',
  'Obsolete external row stays hidden with only Show External toggled on');

# Toggling Show Obsolete as well finally reveals the row.
$sel->click_ok('attachments-obsolete-btn');
sleep(1);
is(row_display($external2_id), '',
  'Obsolete external row is visible once both toggles are on');

logout($sel);
