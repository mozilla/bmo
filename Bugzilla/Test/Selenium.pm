# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Test::Selenium;

use 5.10.1;
use Bugzilla::Logging;
use Bugzilla::Util qw(trim);
use Mojo::File;
use Moo;
use Test2::V0;
use Test::Selenium::Firefox;
use Try::Tiny;

has 'driver_class' => (is => 'ro', default => 'Test::Selenium::Firefox');
has 'driver_args' => (is => 'ro', required => 1,);
has 'driver'      => (
  is      => 'lazy',
  handles => [qw(
      add_cookie
      alert_text_like
      body_text_contains
      body_text_lacks
      clear_element_ok
      click_element_ok
      get_all_cookies
      get_ok
      get_title
      go_back_ok
      refresh
      send_keys_to_active_element
      set_implicit_wait_timeout
      title_is
      title_isnt
      title_like
      )],
);

sub click_ok {
  my ($self, $locator, $arg1, $desc) = @_;
  $arg1 ||= 'undefined';
  $desc ||= "Click ok: $locator";
  TRACE("click_ok: $locator, $arg1, $desc");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    TRACE("click_ok new locator: $locator");
    $element = $self->find_element($locator);
  }

  # Scroll element to center of viewport before clicking to prevent
  # fixed header/nav elements from intercepting the click.
  $self->scroll_to_center($element) if $element;

  $self->driver->click_element_ok($locator, 'xpath', $arg1, $desc);
}

sub scroll_to_center {
  my ($self, $element) = @_;
  $element->execute_script(
    'arguments[0].scrollIntoView({block: "center", inline: "nearest"})');
}

# Use instead of click_ok for elements that don't trigger navigation but are
# unreliable with WebDriver's native click (e.g. small buttons in containers
# where ChromeDriver's own scroll-to-click fails with "not interactable").
sub js_click_ok {
  my ($self, $locator, $desc) = @_;
  $desc ||= "Click ok: $locator";
  TRACE("js_click_ok: $locator, $desc");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    TRACE("js_click_ok new locator: $locator");
    $element = $self->find_element($locator);
  }
  if ($element) {
    $self->scroll_to_center($element);
    $element->execute_script('arguments[0].click()');
    ok(1, $desc);
  }
  else {
    ok(0, $desc);
  }
}

sub open_ok {
  my ($self, $arg1, $arg2, $name) = @_;
  $arg2 ||= 'undefined';
  $name ||= "open_ok: $arg1";
  TRACE("open_ok: $arg1, $arg2, $name");
  $self->get_ok($arg1, $name);
}

sub type_ok {
  my ($self, $locator, $text, $desc) = @_;
  $desc ||= '';
  TRACE("type_ok: $locator, $text, $desc");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
    if (!$element) {
      ok(0, $desc);
      return;
    }
  }
  $element->clear();    # Some fields have a default value
  $self->driver->type_element_ok($locator, 'xpath', $text, $desc);
}

sub wait_for_page_to_load_ok {
  my ($self, $timeout) = @_;
  TRACE("wait_for_page_to_load_ok: $timeout");
  ok($self->driver->set_timeout('page load', $timeout),
    "Wait for page to load: $timeout");
}

sub wait_for_page_to_load {
  my ($self, $timeout) = @_;
  TRACE("wait_for_page_to_load: $timeout");
  $self->driver->set_timeout('page load', $timeout);
}

sub is_text_present {
  my ($self, $text) = @_;
  TRACE("is_text_present: $text");
  return 0 unless $text;
  # Execute script directly because `get_body()` doesn't contain hidden text
  my $body = $self->driver->execute_script(
    "return document.body.textContent.replace(/\\s+/g, ' ')");
  if ($text =~ /^regexp:(.*)$/) {
    return $body =~ /$1/ ? 1 : 0;
  }
  my $index = index $body, $text;
  return ($index >= 0) ? 1 : 0;
}

sub is_text_present_ok {
  my ($self, $text) = @_;
  TRACE("is_text_present_ok: $text");
  ok($self->is_text_present($text), "Text is present: $text");
}

sub find_element {
  my ($self, $locator, $method) = @_;
  $method ||= 'xpath';
  TRACE("find_element: $locator $method");
  try {
    return $self->driver->find_element($locator, $method);
  }
  catch {
    return undef;
  };
}

sub is_element_present {
  my ($self, $locator) = @_;
  TRACE("is_element_present: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }
  return $element;
}

sub is_element_present_ok {
  my ($self, $locator) = @_;
  TRACE("is_element_present_ok: $locator");
  ok($self->is_element_present($locator), "Element is present: $locator");
}

sub is_enabled {
  my ($self, $locator) = @_;
  TRACE("is_enabled: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  return $element && $element->is_enabled ? 1 : 0;
}

sub is_selected {
  my ($self, $locator) = @_;
  TRACE("is_selected: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }
  return $element && $element->is_selected ? 1 : 0;
}

sub get_body_text {
  my ($self) = @_;
  TRACE('get_body_text');
  return $self->driver->get_body();
}

sub get_value {
  my ($self, $locator) = @_;
  TRACE("get_value: $locator");
  $locator = $self->_fix_locator($locator, 'name');
  my $element = $self->find_element($locator);
  if ($element) {
    return $element->get_value();
  }
  return '';
}

sub get_text {
  my ($self, $locator) = @_;
  TRACE("get_text: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if ($element) {
    return $element->get_text();
  }
  return '';
}

sub selected_label_is {
  my ($self, $id, $label) = @_;
  TRACE("selected_label_is: $id, $label");
  my $locator = qq{//select[\@id="$id"]};
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }
  my @options;
  try {
    @options = $self->driver->find_elements($locator . '/option');
  };
  foreach my $option (@options) {
    my $text = trim($option->get_text());
    if ($text eq $label && $option->get_property('selected')) {
      ok(1, "Selected label is: $label");
      return;
    }
  }
  ok(0, "Selected label is: $label");
}

sub get_selected_labels {
  my ($self, $locator) = @_;
  TRACE("get_selected_labels: $locator");
  $locator = $self->_fix_locator($locator);
  my @elements;
  try {
    @elements = $self->driver->find_elements($locator . '/option');
  };
  if (@elements) {
    my @selected;
    foreach my $element (@elements) {
      next if !$element->is_selected();
      push @selected, $element->get_text();
    }
    return @selected;
  }
  return undef;
}

sub get_select_options {
  my ($self, $locator) = @_;
  TRACE("get_select_options: $locator");
  $locator = $self->_fix_locator($locator);
  my @elements;
  try {
    @elements = $self->driver->find_elements($locator . '/option');
  };
  if (@elements) {
    my @options;
    foreach my $element (@elements) {
      push @options, $element->get_text();
    }
    return @options;
  }
  return undef;
}

sub remove_all_selections {
  my ($self, $id) = @_;
  TRACE("remove_all_selections: $id");
  my $locator = $self->_fix_locator($id);
  if ($self->find_element($locator)) {
    $self->driver->execute_script(
      'document.getElementById(arguments[0]).selectedIndex = -1;', $id);
    sleep(1); # FIXME: timing issue when running under CircleCI
    return 1;
  }
  return 0;
}

sub remove_all_selections_ok {
  my ($self, $id) = @_;
  TRACE("remove_all_selections_ok: $id");
  ok($self->remove_all_selections($id), "Remove all selections ok: $id");
}

sub is_checked {
  my ($self, $locator) = @_;
  TRACE("is_checked: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }
  if ($element) {
    return $element->is_selected() ? 1 : 0;
  }
  return 0;
}

sub is_checked_ok {
  my ($self, $locator) = @_;
  TRACE("is_checked_ok: $locator");
  ok($self->is_checked($locator), "Is checked: $locator");
}

sub select_ok {
  my ($self, $locator, $label) = @_;
  TRACE("select_ok: $locator, $label");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }

  # Scroll select element to center of viewport before clicking options to
  # prevent fixed header/nav elements from intercepting the click.
  $self->scroll_to_center($element) if $element;

  my @options;
  try {
    @options = $self->driver->find_elements($locator . '/option');
  };
  my ($is_label, $is_value);
  if ($label =~ /^label=(.*)$/) {
    $label    = $1;
    $is_label = 1;
  }
  elsif ($label =~ /^value=(.*)$/) {
    $label    = $1;
    $is_value = 1;
  }
  foreach my $option (@options) {
    my $value;
    if ($is_label) {
      $value = $option->get_text();
    }
    elsif ($is_value) {
      $value = $option->get_value();
    }
    else {
      $value = $option->get_text();
    }
    $value = trim($value);
    if ($value eq $label) {
      if ($option->get_property('selected')) {
        ok(1, "Set selected: $label");
      }
      else {
        ok($option->click(), "Set selected: $label");
      }
      return;
    }
  }
  ok(0, "Set selected: $label");
}

sub check_ok {
  my ($self, $locator) = @_;
  TRACE("check_ok: $locator");
  ok($self->_toggle_check($locator, 1), "Check OK: $locator");
}

sub uncheck_ok {
  my ($self, $locator) = @_;
  TRACE("uncheck_ok: $locator");
  ok($self->_toggle_check($locator, 0), "Uncheck OK: $locator");
}

sub get_location {
  my ($self) = @_;
  TRACE('get_location');
  return $self->driver->get_current_url();
}

sub value_is {
  my ($self, $locator, $value) = @_;
  TRACE("value_is: $locator $value");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }

  # checkboxes
  if ($value eq 'on') {
    ok($element->is_selected(), 'Value is on');
  }
  elsif ($value eq 'off') {
    ok(!$element->is_selected(), 'Value is off');
  }
  else {
    # other
    ok($element->get_value() eq $value, "Value is: $value");
  }
}

sub get_attribute {
  my ($self, $locator) = @_;
  TRACE("get_attribute: $locator");
  my $attr;
  ($locator, $attr) = ($locator =~ /(.*)@([^@]+)$/);
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if ($element) {
    return $element->get_attribute($attr);
  }
  return undef;
}

sub submit {
  my ($self, $locator) = @_;
  TRACE("submit: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator)->submit();
}

sub is_editable {
  my ($self, $locator) = @_;
  TRACE("is_editable: $locator");
  $locator = $self->_fix_locator($locator);
  my $element = $self->find_element($locator);
  if ($element) {
    TRACE("is_editable found element");
    return $element->is_enabled() ? 1 : 0;
  }
  return 0;
}

sub is_editable_ok {
  my ($self, $locator) = @_;
  TRACE("is_editable_ok: $locator");
  ok($self->is_editable($locator), "Is editable: $locator");
}

# Here we simply load the attachment text into the textarea of
# attachment page for Bugzilla or the enter bug page. We do this
# currently since Firefox is actually running in the Selenium
# container and not the same host as the test scripts. Therefore
# specifying the path the attachment file using the Browse button
# will not work as the file is not in the same container as Firefox.
sub attach_file {
  my ($self, $locator, $filename) = @_;
  my $path = Mojo::File->new($filename);
  # Click the Enter Text button to show the textarea for attachment data
  $self->click_ok('att-enter-button');
  $self->type_ok('att-textarea', $path->slurp, 'Add attachment data');
}

# Private Helpers

sub _build_driver {
  my ($self) = @_;
  $self->driver_class->new(%{$self->driver_args});
}

sub _fix_locator {
  my ($self, $locator, $type) = @_;
  $type ||= 'id';
  TRACE("_fix_locator old: $locator type: $type");
  if ($locator =~ /^link=(.*)$/) {
    $locator = qq{//a[normalize-space(text())="$1"]};
  }
  if ($locator =~ /^name=(.*)$/) {
    $locator = qq{//input[\@name="$1"]};
  }
  if ($locator !~ /^\/\//) {
    $locator = qq{//*[\@$type="$locator"]};
  }
  TRACE("_fix_locator new: $locator");
  return $locator;
}

sub _toggle_check {
  my ($self, $locator, $check) = @_;
  $locator = $self->_fix_locator($locator, 'id');
  my $element = $self->find_element($locator);
  if (!$element) {
    $locator =~ s/\@id/\@name/;
    $element = $self->find_element($locator);
  }
  if ($element) {
    if (($check && !$element->is_selected) || (!$check && $element->is_selected)) {
      $element->toggle();
    }
    return 1;
  }
  return 0;
}

# New utility methods used by t/bmo/*.t tests
# Use these for any new scripts

sub get_token {
  my $token;
  my $count = 0;
  do {
    sleep 1 if $count++;
    open my $fh, '<', '/app/data/mailer.testfile';
    my $content = do {
      local $/ = undef;
      <$fh>;
    };
    ($token) = $content =~ m!/token\.cgi\?t=3D([^&]+)&a=3Dcfmpw!s;
    close $fh;
  } until $token || $count > 60;
  return $token;
}

sub search_mailer_testfile {
  my ($self, $regexp) = @_;
  my $content = "";
  my @result;
  my $count = 0;
  do {
    sleep 1 if $count++;
    open my $fh, '<', '/app/data/mailer.testfile';
    $content .= do {
      local $/ = undef;
      <$fh>;
    };
    close $fh;
    my $decoded = $content;
    $decoded =~ s/\r\n/\n/gs;
    $decoded =~ s/=\n//gs;
    $decoded =~ s/=([[:xdigit:]]{2})/chr(hex($1))/ges;
    @result = $decoded =~ $regexp;
  } until @result || $count > 60;
  return @result;
}

sub click_and_type {
  my ($self, $name, $text) = @_;
  $self->click_ok(qq{//*[\@id="bugzilla-body"]//input[\@name="$name"]}, "Click on $name");
  $self->send_keys_to_active_element($text);
}

sub click_link {
  my ($self, $text) = @_;
  my $el = $self->find_element($text, 'link_text');
  $el->click();
}

sub change_password {
  my ($self, $old, $new1, $new2) = @_;
  $self->get_ok('/userprefs.cgi?tab=account', 'Go to user preferences');
  $self->title_is('User Preferences', 'User preferences loaded');
  $self->click_and_type('old_password',  $old);
  $self->click_and_type('new_password1', $new1);
  $self->click_and_type('new_password2', $new2);
  $self->click_ok('//input[@value="Submit Changes"]');
}

sub toggle_require_password_change {
  my ($self, $login) = @_;
  $self->get_ok('/editusers.cgi', 'Go to edit users');
  $self->title_is('Search users', 'Edit users loaded');
  $self->type_ok('matchstr', $login, "Type $login for search");
  $self->click_ok('//input[@id="search"]');
  $self->title_is('Select user', 'Select a user loaded');
  $self->click_link($login);
  $self->find_element('//input[@id="password_change_required"]')->click;
  $self->click_ok('//input[@id="update"]');
  $self->title_is("User $login updated", "User $login updated");
}

sub enable_user_account {
  my ($self, $login) = @_;
  $self->get_ok('/editusers.cgi', 'Go to edit users');
  $self->title_is('Search users', 'Edit users loaded');
  $self->type_ok('matchstr', $login, "Type $login for search");
  $self->click_ok('//input[@id="search"]');
  $self->title_is('Select user', 'Select a user loaded');
  $self->click_link($login);
  $self->type_ok('disabledtext', '', 'Clear disabled text');
  $self->uncheck_ok('disable_mail');
  $self->click_ok('//input[@id="update"]');
  $self->title_is("User $login updated", "User $login updated");
}

sub login {
  my ($self, $username, $password) = @_;
  $self->get_ok('/login', undef, 'Go to the home page');
  $self->title_is('Log in to Bugzilla', 'Log in to Bugzilla');
  $self->type_ok('Bugzilla_login',    $username, "Enter login name $username");
  $self->type_ok('Bugzilla_password', $password, "Enter password $password");
  $self->click_ok('log_in', undef, 'Submit credentials');
}

sub login_ok {
  my $self = shift;
  $self->login(@_);
  $self->title_is('Bugzilla Main Page', 'User is logged in');
}

sub logout_ok {
  my ($self) = @_;
  $self->get_ok('/index.cgi?logout=1', 'Logout current user');
  $self->title_is('Logged Out', 'Logged Out');
}

1;
