# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

#################
#Bugzilla Test 7#
#####Util.pm#####

use 5.10.1;
use strict;
use warnings;

use lib qw(. lib local/lib/perl5 t);
use Support::Files;
use Test::More tests => 58;
use DateTime;

BEGIN {
  use_ok('Bugzilla');
  use_ok('Bugzilla::Util');
}

# We need to override user preferences so we can get an expected value when
# Bugzilla::Util::format_time() calls ask for the 'timezone' user preference.
Bugzilla->user->{'settings'}->{'timezone'}->{'value'} = "local";

# We need to know the local timezone for the date chosen in our tests.
# Below, tests are run against Nov. 24, 2002.
my $tz = Bugzilla->local_timezone->short_name_for_datetime(
  DateTime->new(year => 2002, month => 11, day => 24));

# we don't test the taint functions since that's going to take some more work.
# XXX: test taint functions

#html_quote():
is(html_quote("<lala&@>"), "&lt;lala&amp;&#64;&gt;", 'html_quote');

#url_quote():
is(url_quote("<lala&>gaa\"'[]{\\"),
  "%3Clala%26%3Egaa%22%27%5B%5D%7B%5C", 'url_quote');

#trim():
is(trim(" fg<*\$%>+=~~ "), 'fg<*$%>+=~~', 'trim()');

#format_time();
is(
  format_time("2002.11.24 00:05"),
  "2002-11-24 00:05 $tz",
  'format_time("2002.11.24 00:05") is ' . format_time("2002.11.24 00:05")
);
is(
  format_time("2002.11.24 00:05:56"),
  "2002-11-24 00:05:56 $tz",
  'format_time("2002.11.24 00:05:56")'
);
is(
  format_time("2002.11.24 00:05:56", "%Y-%m-%d %R"),
  '2002-11-24 00:05',
  'format_time("2002.11.24 00:05:56", "%Y-%m-%d %R") (with no timezone)'
);
is(
  format_time("2002.11.24 00:05:56", "%Y-%m-%d %R %Z"),
  "2002-11-24 00:05 $tz",
  'format_time("2002.11.24 00:05:56", "%Y-%m-%d %R %Z") (with timezone)'
);

# email_filter
my %email_strings = (
  'somebody@somewhere.com'            => 'somebody',
  'Somebody <somebody@somewhere.com>' => 'Somebody <somebody>',
  'One Person <one@person.com>, Two Person <two@person.com>' =>
    'One Person <one>, Two Person <two>',
  'This string contains somebody@somewhere.com and also this@that.com' =>
    'This string contains somebody and also this',
);

foreach my $input (keys %email_strings) {
  is(Bugzilla::Util::email_filter($input),
    $email_strings{$input}, "email_filter('$input')");
}

# validate_email_syntax. We need to override some parameters.
my $params = Bugzilla->params;
$params->{emailregexp} = '.*';
$params->{emailsuffix} = '';
my $ascii_email = 'admin@company.com';

# U+0430 returns the Cyrillic "а", which looks similar to the ASCII "a".
my $utf8_email = "\N{U+0430}dmin\@company.com";
ok(validate_email_syntax($ascii_email),
  'correctly formatted ASCII-only email address is valid');
ok(!validate_email_syntax($utf8_email),
  'correctly formatted email address with non-ASCII characters is rejected');

# is_fake_recipient_address
ok(!is_fake_recipient_address('foo@example.com'), 'Non-fake email address is accepted');
ok(is_fake_recipient_address('foo@example.tld'), 'Fake email address is denied');
ok(is_fake_recipient_address('nobody@mozilla.org'), 'Fake default assignee for BMO is denied');

# diff_arrays():
my @old_array = qw(alpha beta alpha gamma gamma beta alpha delta epsilon gamma);
my @new_array = qw(alpha alpha beta gamma epsilon delta beta delta);

# The order is not relevant when comparing both arrays for matching items,
# i.e. (foo bar) and (bar foo) are the same arrays (same items).
# But when returning data, we try to respect the initial order.
# We remove the leftmost items first, and return what's left. This means:
# Removed (in this order): gamma alpha gamma.
# Added (in this order): delta
my ($removed, $added) = diff_arrays(\@old_array, \@new_array);
is_deeply($removed, [qw(gamma alpha gamma)],
  'diff_array(\@old, \@new) (check removal)');
is_deeply($added, [qw(delta)], 'diff_array(\@old, \@new) (check addition)');

# time_ago():
# Test with seconds
is(time_ago(5), 'Just now', 'time_ago(5) returns "Just now"');
is(time_ago(9), 'Just now', 'time_ago(9) returns "Just now"');
is(time_ago(10), '10 seconds ago', 'time_ago(10) returns "10 seconds ago"');
is(time_ago(30), '30 seconds ago', 'time_ago(30) returns "30 seconds ago"');
is(time_ago(44), '44 seconds ago', 'time_ago(44) returns "44 seconds ago"');

# Test minute boundaries
is(time_ago(45), '1 minute ago', 'time_ago(45) returns "1 minute ago"');
is(time_ago(60), '1 minute ago', 'time_ago(60) returns "1 minute ago"');
is(time_ago(90), '1 minute ago', 'time_ago(90) returns "1 minute ago"');
is(time_ago(119), '1 minute ago', 'time_ago(119) returns "1 minute ago"');
is(time_ago(120), '2 minutes ago', 'time_ago(120) returns "2 minutes ago"');

# Test hour boundaries - critical for the bug fix
is(time_ago(60 * 44), '44 minutes ago', 'time_ago(44 minutes) returns "44 minutes ago"');
is(time_ago(60 * 60), '1 hour ago', 'time_ago(60 minutes) returns "1 hour ago"');
is(time_ago(60 * 90), '1 hour ago', 'time_ago(90 minutes) returns "1 hour ago"');
is(time_ago(60 * 119), '1 hour ago', 'time_ago(119 minutes) returns "1 hour ago"');
is(time_ago(60 * 120), '2 hours ago', 'time_ago(2 hours) returns "2 hours ago"');

# Test day boundaries - this is where the bug was most visible
is(time_ago(60 * 60 * 23), '23 hours ago', 'time_ago(23 hours) returns "23 hours ago"');
is(time_ago(60 * 60 * 24), '1 day ago', 'time_ago(24 hours) returns "1 day ago"');
is(time_ago(60 * 60 * 36), '1 day ago', 'time_ago(36 hours) returns "1 day ago"');
is(time_ago(60 * 60 * 47), '1 day ago', 'time_ago(47 hours) returns "1 day ago"');
is(time_ago(60 * 60 * 48), '2 days ago', 'time_ago(48 hours) returns "2 days ago"');
is(time_ago(60 * 60 * 72), '3 days ago', 'time_ago(72 hours) returns "3 days ago"');

# Test month boundaries
is(time_ago(60 * 60 * 24 * 29), '29 days ago', 'time_ago(29 days) returns "29 days ago"');
is(time_ago(60 * 60 * 24 * 30), '1 month ago', 'time_ago(30 days) returns "1 month ago"');
is(time_ago(60 * 60 * 24 * 45), '1 month ago', 'time_ago(45 days) returns "1 month ago"');
is(time_ago(60 * 60 * 24 * 59), '1 month ago', 'time_ago(59 days) returns "1 month ago"');
is(time_ago(60 * 60 * 24 * 60), '2 months ago', 'time_ago(60 days) returns "2 months ago"');

# Test year boundaries
is(time_ago(60 * 60 * 24 * 365), '1 year ago', 'time_ago(365 days) returns "1 year ago"');
is(time_ago(60 * 60 * 24 * 547), '1 year ago', 'time_ago(547 days) returns "1 year ago"');
is(time_ago(60 * 60 * 24 * 731), '2 years ago', 'time_ago(731 days) returns "2 years ago"');

# Test with DateTime object
my $now = DateTime->now();
my $past = $now->clone->subtract(hours => 25);
is(time_ago($past), '1 day ago', 'time_ago(DateTime 25 hours ago) returns "1 day ago"');

$past = $now->clone->subtract(days => 2);
is(time_ago($past), '2 days ago', 'time_ago(DateTime 2 days ago) returns "2 days ago"');

$past = $now->clone->subtract(months => 1);
like(time_ago($past), qr/^(1 month|(2[89]|3[01]) days) ago$/, 'time_ago(DateTime 1 month ago) is reasonable');

# mermaid_quote():
is(mermaid_quote('foo(bar)'),    'foo#40;bar#41;',    'mermaid_quote: parens');
is(mermaid_quote('foo[bar]'),    'foo#91;bar#93;',    'mermaid_quote: brackets');
is(mermaid_quote('foo"bar"'),    'foo#34;bar#34;',    'mermaid_quote: double quotes');
is(mermaid_quote('<script>'),    '#60;script#62;',    'mermaid_quote: angle brackets (html injection)');
is(mermaid_quote('$$x$$'),       '#36;#36;x#36;#36;', 'mermaid_quote: dollar signs (katex math)');
is(mermaid_quote('no specials'), 'no specials',       'mermaid_quote: passthrough');
