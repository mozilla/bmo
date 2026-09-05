# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use QA::Util;
use Test::More;

my ($sel, $config) = get_selenium();

$sel->set_implicit_wait_timeout(600);

# Setup the parameters properly for Duo Security 2FA
log_in($sel, $config, 'admin');
set_parameters(
  $sel,
  {
    'User Authentication' =>
      {'duo_uri' => {type => 'text', value => 'http://externalapi.test:8001'},}
  }
);

# Enable Duo for the admin user
$sel->open_ok('/userprefs.cgi?tab=mfa');
$sel->title_is('User Preferences');
$sel->click_ok('mfa-select-duo');
$sel->type_ok('mfa-duo-user', $config->{admin_user_login});
$sel->type_ok('mfa-password', $config->{admin_user_passwd});
$sel->click_ok('update');
$sel->click_ok('//a[contains(text(),"Redirect Back")]',
  'Click Duo Security verification');
$sel->title_is('User Preferences');
$sel->is_text_present_ok(
  'The changes to your two-factor authentication have been saved',
  'Duo successfully enabled');

ok(
  $sel->is_element_present('mfa-disable'),
  'Duo preferences are displayed'
);
ok(
  !$sel->is_element_present('mfa-recovery'),
  'Recovery code generation is not offered for Duo'
);

# A forged recovery request must fail before opening the Duo prompt.
$sel->driver->execute_script(
  q{document.getElementById('mfa-auth-container').style.display = 'block';}
);
$sel->type_ok('mfa-password', $config->{admin_user_passwd});
$sel->driver->execute_script(q{
  const source = document.forms.userprefsform;
  const form = document.createElement('form');
  form.method = 'post';
  form.action = source.action;

  [
    ['tab', 'mfa'],
    ['token', source.elements.token.value],
    ['dosave', '1'],
    ['mfa_action', 'recovery'],
    ['mfa', 'TOTP'],
    ['password', source.elements.password.value],
  ].forEach(([name, value]) => {
    const input = document.createElement('input');
    input.type = 'hidden';
    input.name = name;
    input.value = value;
    form.appendChild(input);
  });

  document.body.appendChild(form);
  form.submit();
});
foreach (1 .. WAIT_TIME / 1000) {
  last if $sel->get_title eq 'Duo Security Error';
  sleep 1;
}
$sel->title_is('Duo Security Error');
$sel->is_text_present_ok(
  'Recovery codes are not available when using Duo Security',
  'Forged Duo recovery request rejected'
);

# Disable Duo for the admin user
$sel->open_ok('/userprefs.cgi?tab=mfa');
$sel->click_ok('mfa-disable');
$sel->type_ok('mfa-password', $config->{admin_user_passwd});
$sel->click_ok('update');
$sel->click_ok('//a[contains(text(),"Redirect Back")]',
  'Click Duo Security verification');
$sel->title_is('User Preferences');
$sel->is_text_present_ok(
  'The changes to your two-factor authentication have been saved',
  'Duo successfully disabled');

done_testing;
