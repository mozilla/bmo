.. _two-factor-authentication:

Two-Factor Authentication
#########################

Two-factor authentication (2FA) protects your account with two independent
credentials: your password and a second factor. If someone learns your password,
they still cannot sign in without access to your second factor.

BMO supports two methods:

* **Time-based one-time passwords (TOTP)** are available unless your account
  belongs to a group that requires Duo. A TOTP application generates a new
  six-digit code every 30 seconds.
* **Duo Security** is available to eligible Mozilla-affiliated accounts. Some
  Mozilla groups require their members to use Duo.

For the strongest separation between factors, keep your password and TOTP
generator on different devices or in different applications. A password manager
that stores both your BMO password and TOTP secret is convenient and still
protects against some attacks, but anyone who compromises that password manager
may obtain both factors.

After you enable 2FA, BMO asks for second-factor verification when you sign in
and when you perform sensitive account actions, such as changing your email
address or password, creating an API key, or relaxing API authentication
requirements. Enabling or disabling 2FA also signs out your other BMO sessions.

Enabling 2FA turns on the
:guilabel:`Require API key authentication for API requests` preference.
Applications and scripts that use the BMO API should authenticate with an
:ref:`API key <api-keys>` instead of your password. You can turn this preference
off after verifying with your second factor, but doing so is not recommended.

.. _required-two-factor-enrollment:

Required 2FA Enrollment
=======================

If BMO displays a 2FA enrollment deadline, enable 2FA before the date shown.
After that deadline, BMO restricts your account to the 2FA preferences page
until enrollment is complete.

Some accounts are required to use Duo. If an account is used for automation
and Duo is not appropriate, `file a bug in the bugzilla.mozilla.org
Administration component
<https://bugzilla.mozilla.org/enter_bug.cgi?product=bugzilla.mozilla.org&component=Administration>`_
with details about the bot and its requirements to request an exception.

.. _choose-two-factor-method:

Choose a Method
===============

Before you begin:

* Make sure you know your current BMO password.
* For TOTP, install a TOTP application on a device you control and set the
  device's date and time automatically.
* For Duo, complete enrollment at `login.mozilla.com
  <https://login.mozilla.com/>`_ and have your Duo username ready.

Open `BMO's Two-Factor Authentication preferences
<https://bugzilla.mozilla.org/userprefs.cgi?tab=mfa>`_, or open
:guilabel:`Preferences` and select the :guilabel:`Two-Factor Authentication`
tab. Choose an available method.

.. figure:: ../../images/mfa-method-selection.png
   :alt: BMO Two-Factor Authentication preferences showing TOTP and Duo choices

   Choose TOTP or, if your account is eligible, Duo Security.

You must have a password on your BMO account before you can enable 2FA. If your
account does not have one, use :guilabel:`Reset Password` and follow the link
sent to your email address.

.. _configure-totp:

Configure TOTP
==============

`Google Authenticator <https://support.google.com/accounts/answer/1066447>`_,
`FreeOTP <https://freeotp.github.io/>`_, and other applications compatible with
the TOTP standard can generate BMO verification codes. The exact labels vary by
application, but the enrollment process is the same:

#. Click :guilabel:`Time-based One-Time Password (TOTP)`.
#. Enter your current BMO password.
#. In your TOTP application, add a new account and choose the option to scan a
   QR code. Allow camera access if the application requests it.
#. Point the device's camera at the QR code shown by BMO. The application should
   add a BMO entry and begin showing a new six-digit code every 30 seconds.
#. If you cannot scan the QR code, click :guilabel:`Show as text` above it to
   display the secret, then choose manual entry in your TOTP application and
   enter that secret.
#. Enter the six-digit code shown by your TOTP application.
#. Click :guilabel:`Submit Changes`.

BMO returns to the 2FA preferences page and shows TOTP as enabled. Generate
recovery codes before signing out or removing the BMO entry from your TOTP
application.

.. figure:: ../../images/mfa-totp-enrollment.png
   :alt: BMO TOTP enrollment form with a QR code and verification fields

   Scan the QR code, then verify enrollment with your password and a current
   six-digit code.

.. warning::

   The QR code and manual secret can generate verification codes for your
   account. Do not save screenshots of them or share them with anyone.

.. _configure-duo:

Configure Duo
=============

Duo appears only when BMO marks your account as eligible. This includes Mozilla
employees and members of groups required to use Duo; having a Mozilla LDAP
account alone does not guarantee eligibility. Before enabling Duo in BMO, enroll
your account at `login.mozilla.com <https://login.mozilla.com/>`_.

#. Click :guilabel:`Duo Security`.
#. Enter your current BMO password.
#. Enter your Mozilla Duo username, which is generally your Mozilla LDAP
   username and may differ from your BMO email address.
#. Click :guilabel:`Submit Changes`.
#. Complete the Duo Universal Prompt.

The Duo application and a TOTP application are not interchangeable. When BMO
shows the Duo Universal Prompt, approve the request using a method enrolled in
Duo; do not enter a TOTP code created for BMO.

If your group requires Duo, BMO does not offer the option to disable it in your
2FA preferences. Contact `Mozilla Service Desk`_ if you need help with your Duo
enrollment or device.

.. _use-two-factor-authentication:

Sign In and Confirm Sensitive Changes
=====================================

After entering your email address and password, BMO completes sign-in using the
method configured on your account:

* TOTP users enter the current six-digit code from their TOTP application. An
  unused BMO recovery code also works in this field.
* Duo users complete the Duo Universal Prompt using an enrolled Duo method. BMO
  recovery codes do not replace this prompt.

BMO asks you to verify again before sensitive account changes. Read the prompt
carefully and use the same method. Never approve an unexpected Duo request or
give a TOTP or recovery code to another person.

.. _two-factor-recovery-codes:

Generate Recovery Codes
=======================

For TOTP accounts, recovery codes let you verify your identity if your normal
second factor is lost, unavailable, or replaced. Generate them immediately
after enabling TOTP.

#. Return to the :guilabel:`Two-Factor Authentication` preferences tab.
#. Click :guilabel:`Generate Printable Recovery Codes`.
#. Enter your current password and either a current TOTP code or an unused
   recovery code.
#. Click :guilabel:`Generate Printable Recovery Codes` again to submit the
   form.
#. Print the codes and store them in a secure offline location.

.. figure:: ../../images/mfa-enabled.png
   :alt: BMO preferences showing enabled TOTP and the recovery-code button

   Generate recovery codes from the preferences page after enabling 2FA.

.. figure:: ../../images/mfa-recovery-codes.png
   :alt: BMO printable recovery-code page showing ten single-use codes

   BMO displays ten printable recovery codes.

Each recovery code is a nine-digit, single-use code. Enter one in the same field
that normally accepts your TOTP code. Generating a new set immediately
invalidates every code from the previous set.

Do not store recovery codes with your password or on the device that provides
your second factor. If you are unsure whether your codes remain private,
generate and print a new set.

BMO does not offer its recovery-code generator for Duo accounts because BMO
recovery codes cannot replace a Duo verification. Duo users should configure
more than one authentication method in Duo and contact `Mozilla Service Desk`_
if none of those methods are available.

.. _two-factor-troubleshooting:

Troubleshooting
===============

.. _two-factor-totp-code-rejected:

TOTP Code Is Rejected
---------------------

#. Make sure you are using the code from the BMO entry in your TOTP application,
   not a Duo passcode or a code for another service.
#. Set the device's date and time automatically. TOTP depends on an accurate
   clock.
#. If the displayed code is about to expire, wait for the next code and enter it
   promptly.
#. Enter only the six digits shown by the application.

If current codes continue to fail and you are already signed in, use an unused
recovery code to :ref:`disable and re-enable TOTP
<change-two-factor-method>`. If you are signed out, you need two unused recovery
codes: one to sign in and another to disable TOTP. Otherwise, contact the BMO
administrators.

.. _two-factor-duo-prompt-not-load:

Duo Prompt Does Not Load
------------------------

Content-blocking or privacy extensions can prevent the Duo Universal Prompt from
loading. Temporarily allow the Duo page, reload BMO, and try again. Also confirm
that the Duo username configured in BMO belongs to your Mozilla account.

If the prompt still does not load, or none of your enrolled Duo methods is
available, contact `Mozilla Service Desk`_.

.. _two-factor-no-method-available:

No 2FA Method Is Available
--------------------------

BMO requires a password before it can enable 2FA. If your account signs in
through an external identity provider and does not yet have a BMO password, use
:guilabel:`Reset Password` on the 2FA preferences page and follow the link sent
to your email address.

.. _lost-two-factor-device:

If You Lose Your Device
=======================

If you use TOTP and have recovery codes:

#. Sign in with your password and one unused recovery code.
#. Open the :guilabel:`Two-Factor Authentication` preferences tab.
#. Click :guilabel:`Disable Two-factor Authentication`.
#. Enter your current password and verify with another unused recovery code.
#. Click :guilabel:`Submit Changes`.
#. Enable 2FA again with your replacement device and generate a new set of
   recovery codes.

If you use Duo and still have another enrolled Duo device or recovery method,
use it in the Duo Universal Prompt. Duo users who cannot access an enrolled
method should contact `Mozilla Service Desk`_.

If you have lost both your second factor and all recovery codes, contact
`the BMO administrators <mailto:bugzilla-admin@mozilla.org>`_. You will need to
provide enough information to establish that you own the account. Account
recovery is not guaranteed.

.. _change-two-factor-method:

Change or Disable 2FA
=====================

If your account permits changing methods, first disable the current method,
then enable the new one. You must enter your current password and verify with
your current second factor. TOTP users may verify with an unused recovery code
instead. There is a brief period when your account is not protected by 2FA, so
complete the new enrollment immediately.

When you enable or disable 2FA, BMO signs out every other session while keeping
your current session active. You can also review and end sessions from BMO's
`Sessions preferences
<https://bugzilla.mozilla.org/userprefs.cgi?tab=sessions>`_.

.. _two-factor-frequently-asked-questions:

Frequently Asked Questions
==========================

.. _two-factor-move-totp-new-device:

Can I Move TOTP to a New Device?
--------------------------------

If both devices are available, use your TOTP application's supported transfer
process, then confirm that the new device produces working BMO codes before
removing the old entry. Otherwise, disable TOTP while the old device still
works, enable it again with the new device, and generate new recovery codes.
BMO does not display the original TOTP secret again after enrollment.

.. _two-factor-store-totp-password-manager:

Can I Store TOTP in My Password Manager?
----------------------------------------

Yes, if your password manager supports it, but this places your password and
second factor in the same security boundary. A separate TOTP application or
device provides stronger protection if your password manager is compromised.
Whichever approach you choose, keep recovery codes separately in a secure
offline location.

.. _two-factor-api-client-stopped-working:

Why Did My API Client Stop Working?
-----------------------------------

Enabling 2FA also enables the
:guilabel:`Require API key authentication for API requests` preference.
Password-authenticated scripts may therefore stop working. Create an
:ref:`API key <api-keys>` for the client rather than weakening this preference.

.. _Mozilla Service Desk: https://mozilla-hub.atlassian.net/servicedesk/customer/portal/1
