# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Bugzilla::Util qw(template_var);

use Auth::GoogleAuth;
use Test::More "no_plan";
use Try::Tiny;

use QA::Util;

my ($sel, $config) = get_selenium();
my $mfa_help_url = qr{/using/two-factor-authentication\.md$};

# Enable TOTP for the admin user
log_in($sel, $config, 'admin');

my $dbh = Bugzilla->dbh;
my ($admin_password_hash) = $dbh->selectrow_array(
  'SELECT cryptpassword FROM profiles WHERE login_name = ?',
  undef,
  $config->{admin_user_login}
);
my $passwordless_mfa_help_url;
try {
  $dbh->do(
    q{UPDATE profiles SET cryptpassword = '*' WHERE login_name = ?},
    undef,
    $config->{admin_user_login}
  );
  $sel->open_ok('/userprefs.cgi?tab=mfa');
  $sel->title_is('User Preferences');
  ok(
    $sel->is_element_present(
      '//input[@id="mfa-action"][@data-nopassword="true"]'
    ),
    'Passwordless MFA preferences are displayed'
  );
  $passwordless_mfa_help_url
    = $sel->get_attribute('link=two-factor authentication user guide@href');
}
catch {
  fail('Passwordless MFA preferences could not be verified');
  diag($_);
}
finally {
  $dbh->do(
    'UPDATE profiles SET cryptpassword = ? WHERE login_name = ?',
    undef,
    $admin_password_hash,
    $config->{admin_user_login}
  );
};
like(
  $passwordless_mfa_help_url,
  $mfa_help_url,
  'MFA help is available before setting a password'
);

$sel->open_ok('/userprefs.cgi?tab=mfa');
$sel->title_is('User Preferences');
like(
  $sel->get_attribute('link=two-factor authentication user guide@href'),
  $mfa_help_url,
  'MFA help is available before enrollment'
);
$sel->click_ok('mfa-select-totp');
$sel->type_ok('mfa-password', $config->{admin_user_passwd});

# Hack needed to click the show-text link in the TOTP iframe
# and then return the text based secret
my $secret32 = $sel->driver->execute_script('
  var iframe = document.getElementById("mfa-enable-totp-frame").contentWindow;
  var showText = iframe.document.getElementById("show-text");
  var oEvent = document.createEvent("MouseEvents");
  oEvent.initMouseEvent("click", true, true, window, 1, 1, 1, 1, 1, false, false, false, false, 0, showText);
  showText.dispatchEvent(oEvent);
  var secret = iframe.document.getElementById("secret");
  return secret.innerText;
');

ok($secret32, 'Correctly received secret32 from the form');

# Use the provided secret to generate the code needed to enable TOTP
my $auth = Auth::GoogleAuth->new({
  secret32 => $secret32,
  issuer   => template_var('terms')->{BugzillaTitle},
  key_id   => $config->{admin_user_login},
});

$sel->type_ok('mfa-totp-enable-code', $auth->code);
$sel->click_ok('update');
$sel->title_is('User Preferences');
like(
  $sel->get_attribute('link=two-factor authentication user guide@href'),
  $mfa_help_url,
  'MFA help is available after enrollment'
);

#  Generate recovery codes to use in testing
$sel->click_ok('mfa-recovery');
$sel->type_ok('mfa-password', $config->{admin_user_passwd});
$sel->type_ok('code',         $auth->code);
$sel->click_ok('update');
$sel->is_element_present_ok('mfa-recovery-frame');
like(
  $sel->get_attribute(
    '//div[@id="mfa-container"][.//iframe[@id="mfa-recovery-frame"]]'
      . '//a[normalize-space(text())="two-factor authentication user guide"]@href'
  ),
  $mfa_help_url,
  'MFA help is available with recovery codes'
);

# Hack needed view contents of TOTP iframe and return the recovery codes
my $recovery_string = $sel->driver->execute_script('
  var iframe = document.getElementById("mfa-recovery-frame").contentWindow;
  var codes = iframe.document.getElementById("codes");
  return codes.innerText;
');
my @recovery_codes;
foreach my $code (split /\n/, $recovery_string) {
  $code =~ s/^\s+//;
  $code =~ s/\s+$//;
  push @recovery_codes, $code;
}
ok(scalar @recovery_codes == 10, 'Ten recovery codes generated properly');
logout($sel);

# Log back in but this time we are asked for a TOTP code
$sel->open_ok('/login', undef, 'Go to the home page');
$sel->title_is('Log in to Bugzilla');
$sel->type_ok(
  'Bugzilla_login',
  $config->{admin_user_login},
  'Enter admin login name'
);
$sel->type_ok(
  'Bugzilla_password',
  $config->{admin_user_passwd},
  'Enter admin password'
);
$sel->click_ok('log_in', undef, 'Submit credentials');
$sel->title_is('Account Verification');

# Enter an inccorrect TOTP code
$sel->type_ok('code', '123456');
$sel->click_ok('//input[@value="Submit"]');
my $error = $sel->get_text('verify-totp-error');
ok($error eq 'Invalid verification code.', 'Correct error generated for invalid code');

# Now enter the correct code
$sel->type_ok('code', $auth->code);
$sel->click_ok('//input[@value="Submit"]');
$sel->title_is('Bugzilla Main Page');
logout($sel);

# Try to use one of the recovery codes as a MFA code
$sel->open_ok('/login', undef, 'Go to the home page');
$sel->title_is('Log in to Bugzilla');
$sel->type_ok(
  'Bugzilla_login',
  $config->{admin_user_login},
  'Enter admin login name'
);
$sel->type_ok(
  'Bugzilla_password',
  $config->{admin_user_passwd},
  'Enter admin password'
);
$sel->click_ok('log_in', undef, 'Submit credentials');
$sel->title_is('Account Verification');
$sel->type_ok('code', $recovery_codes[0]);
$sel->click_ok('//input[@value="Submit"]');
$sel->title_is('Bugzilla Main Page');
logout($sel);

# Reusing the same recovery code a second time should fail
$sel->open_ok('/login', undef, 'Go to the home page');
$sel->title_is('Log in to Bugzilla');
$sel->type_ok(
  'Bugzilla_login',
  $config->{admin_user_login},
  'Enter admin login name'
);
$sel->type_ok(
  'Bugzilla_password',
  $config->{admin_user_passwd},
  'Enter admin password'
);
$sel->click_ok('log_in', undef, 'Submit credentials');
$sel->title_is('Account Verification');
$sel->type_ok('code', $recovery_codes[0]);
$sel->click_ok('//input[@value="Submit"]');
$error = $sel->get_text('verify-totp-error');
ok($error eq 'Invalid verification code.', 'Correct error generated for invalid code');

# Now enter a different valid recovery code
$sel->type_ok('code', $recovery_codes[1]);
$sel->click_ok('//input[@value="Submit"]');
$sel->title_is('Bugzilla Main Page');

# Disable TOTP for the admin account
$sel->open_ok('/userprefs.cgi?tab=mfa');
$sel->title_is('User Preferences');
$sel->click_ok('mfa-disable');
$sel->type_ok('mfa-password', $config->{admin_user_passwd});
$sel->type_ok('code', $auth->code);
$sel->click_ok('update');
$sel->title_is('User Preferences');

logout($sel);

done_testing();
