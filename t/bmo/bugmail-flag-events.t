#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 1883428: DB-backed coverage for BugMail flag events --
# _get_flag_mail_events() (previous '?' lookback, 'X' auto-clear, generic
# 'set' events) and flag recipient selection in Send(). The private
# attachment check is covered without a DB in t/bugmail-flag-events.t.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use Test::More;

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::Test::Util qw(create_user);
BEGIN { Bugzilla->extensions }

Bugzilla->usage_mode(USAGE_MODE_TEST);
Bugzilla->error_mode(ERROR_MODE_DIE);

# Don't deliver anything: Send() still builds each recipient's mail and
# returns who it went to.
Bugzilla->params->{mail_delivery_method} = 'None';
Bugzilla->params->{use_mailer_queue}     = 0;

my $dbh = Bugzilla->dbh;
Bugzilla->set_user(Bugzilla::User->check({id => 1}));

my $requester = create_user('flagmail-requester@mozilla.example', '*');
my $requestee = create_user('flagmail-requestee@mozilla.example', '*');
my $type_cc   = create_user('flagmail-typecc@mozilla.example',    '*');
my $stranger  = create_user('flagmail-stranger@mozilla.example',  '*');
my $raw_cc    = 'flagmail-list@mozilla.example';    # no account

# A flag type of our own, so its cc_list is known.
my ($type_id)
  = $dbh->selectrow_array('SELECT id FROM flagtypes WHERE name = ?',
  undef, 'flagmail-test');
if (!$type_id) {
  $dbh->do(
    "INSERT INTO flagtypes (name, description, cc_list, target_type,
                            is_requestable, is_requesteeble, is_multiplicable)
     VALUES (?, ?, ?, 'b', 1, 1, 1)", undef, 'flagmail-test',
    'Bug 1883428 test flag', $type_cc->login . ", $raw_cc"
  );
  $type_id = $dbh->bz_last_key('flagtypes', 'id');
}

# Test rows go straight into flag_activity at fixed times around a pinned
# lastdiffed, so the mail window is deterministic. flag_activity.flag_id
# has no foreign key, so the flags themselves don't need to exist; ids start
# high (below the MEDIUMINT limit) to stay clear of real flags, and above
# any row left by an earlier run: the look-back in _get_flag_mail_events()
# goes by flag_id alone.
my $window_start = '2000-01-01 00:00:00';
my $window_end   = '2000-01-01 01:00:00';
my ($max_flag_id)
  = $dbh->selectrow_array('SELECT MAX(flag_id) FROM flag_activity');
my $next_flag_id
  = ($max_flag_id // 0) < 8_000_000 ? 8_000_000 : $max_flag_id + 1;

sub new_bug {
  my (%extra) = @_;
  my $bug = Bugzilla::Bug->create({
    short_desc   => 'Flag mail test',
    product      => 'Firefox',
    component    => 'General',
    bug_type     => 'defect',
    bug_severity => 'normal',
    groups       => [],
    op_sys       => 'Unspecified',
    rep_platform => 'Unspecified',
    version      => 'Trunk',
    keywords     => [],
    cc           => [],
    comment      => 'Flag mail test',
    assigned_to  => 'nobody@mozilla.org',
    %extra,
  });
  $dbh->do('UPDATE bugs SET lastdiffed = ? WHERE bug_id = ?',
    undef, $window_start, $bug->id);
  return Bugzilla::Bug->new($bug->id);
}

sub add_activity {
  my ($bug, $flag_id, $when, $status, $setter, $requestee) = @_;
  $dbh->do(
    'INSERT INTO flag_activity (flag_when, type_id, flag_id, setter_id,
                                requestee_id, bug_id, status)
     VALUES (?, ?, ?, ?, ?, ?, ?)', undef, $when, $type_id, $flag_id,
    $setter->id, $requestee ? $requestee->id : undef, $bug->id, $status
  );
}

sub sent_to {
  my ($bug, $changer) = @_;
  my $result = Bugzilla::BugMail::Send($bug->id, {changer => $changer});
  return {map { $_ => 1 } @{$result->{sent}}};
}

# Like sent_to(), but returns the template variables of each mail generated.
sub sent_mails {
  my ($bug, $changer) = @_;
  my @mails;
  my $generate = \&Bugzilla::BugMail::_generate_bugmail;

  # local empties the glob first, so this isn't a redefinition.
  local *Bugzilla::BugMail::_generate_bugmail = sub {
    push @mails, {%{$_[0]}};
    return $generate->(@_);
  };
  Bugzilla::BugMail::Send($bug->id, {changer => $changer});
  return @mails;
}

## no critic (Variables::ProtectPrivateVars)

# _get_flag_mail_events: one event per in-window row, classified.
{
  my $bug = new_bug();
  my ($asked, $granted, $auto_cleared, $regranted, $no_requestee, $later)
    = map { $next_flag_id++ } 1 .. 6;

  # Before the window.
  add_activity($bug, $granted,   '1999-12-31 23:00:00', '?', $requester, $requestee);
  add_activity($bug, $regranted, '1999-12-31 23:00:00', '+', $requestee);

  # In the window.
  add_activity($bug, $asked,        '2000-01-01 00:00:10', '?', $requester, $requestee);
  add_activity($bug, $granted,      '2000-01-01 00:00:20', '+', $requestee);
  add_activity($bug, $auto_cleared, '2000-01-01 00:00:30', '?', $requester, $requestee);
  add_activity($bug, $auto_cleared, '2000-01-01 00:00:30', 'X', $requestee);
  add_activity($bug, $regranted,    '2000-01-01 00:00:40', 'X', $requester);
  add_activity($bug, $no_requestee, '2000-01-01 00:00:50', '?', $requester);

  # After the window.
  add_activity($bug, $later, '2000-01-01 02:00:00', '?', $requester, $requestee);

  my @events
    = Bugzilla::BugMail::_get_flag_mail_events($bug, $window_start, $window_end,
    {});

  is_deeply(
    [map { [$_->{action}, $_->{status}] } @events],
    [
      ['requested', '?'], ['answered', '+'], ['requested', '?'],
      ['answered',  'X'], ['set',      'X'], ['set',       '?'],
    ],
    'one event per in-window row, classified'
  );
  is($events[0]{requestee_id}, $requestee->id, 'a request carries its requestee');
  is($events[1]{requester_id}, $requester->id,
    "an answer finds its requester from a '?' before the window");
  is($events[3]{requester_id}, $requester->id,
    "an 'X' auto-clear in the same second as its '?' is an answer");
  ok(!$events[4]{requester_id},
    'clearing an already granted flag has no requester to notify');
}

# Send: a request reaches the requestee and the flag type cc_list only.
{
  my $bug = new_bug();
  add_activity($bug, $next_flag_id++, '2000-01-01 00:00:10', '?', $requester,
    $requestee);
  my $sent = sent_to($bug, $requester);

  ok($sent->{$requestee->login}, 'requestee with no role on the bug is mailed');
  ok($sent->{$type_cc->login},   'flag type cc_list account is mailed');
  ok(!$sent->{$requester->login}, 'requester is not mailed about their own request');
  ok(!$sent->{$stranger->login},  'unrelated user is not mailed');
}

# Send: an answer reaches the requester, not the person who answered.
{
  my $bug     = new_bug();
  my $flag_id = $next_flag_id++;
  add_activity($bug, $flag_id, '1999-12-31 23:00:00', '?', $requester, $requestee);
  add_activity($bug, $flag_id, '2000-01-01 00:00:10', '+', $requestee);
  my $sent = sent_to($bug, $requestee);

  ok($sent->{$requester->login}, 'requester is told their request was answered');
  ok(!$sent->{$requestee->login}, 'answerer is not mailed about their own answer');
}

# Send: mail carrying a flag event keeps "request" in X-Bugzilla-Type, as the
# old flag mail had, whether the flag was requested or answered.
{
  my $bug = new_bug();
  add_activity($bug, $next_flag_id++, '2000-01-01 00:00:10', '?', $requester,
    $requestee);
  my ($mail) = grep { $_->{to_user}->id == $requestee->id }
    sent_mails($bug, $requester);
  is($mail->{bugmailtype}, 'changed request', 'a request is marked as request mail');

  $bug = new_bug();
  my $flag_id = $next_flag_id++;
  add_activity($bug, $flag_id, '1999-12-31 23:00:00', '?', $requester, $requestee);
  add_activity($bug, $flag_id, '2000-01-01 00:00:10', '+', $requestee);
  ($mail) = grep { $_->{to_user}->id == $requester->id }
    sent_mails($bug, $requestee);
  is($mail->{bugmailtype}, 'changed request', 'an answer is marked as request mail');
}

# Send: cancelling your own request doesn't mail you.
{
  my $bug     = new_bug();
  my $flag_id = $next_flag_id++;
  add_activity($bug, $flag_id, '1999-12-31 23:00:00', '?', $requester, $requestee);
  add_activity($bug, $flag_id, '2000-01-01 00:00:10', 'X', $requester);
  my $sent = sent_to($bug, $requester);

  ok(!$sent->{$requester->login}, 'requester is not mailed for cancelling their own request');
  ok($sent->{$type_cc->login},    'flag type cc_list account is still mailed');
}

# Send: someone mailed only because of a flag gets the flag section and the
# comments (so a requestee sees the question), but no diffs.
{
  my $bug = new_bug();
  add_activity($bug, $next_flag_id++, '2000-01-01 00:00:10', '?', $requester,
    $requestee);
  my ($mail) = grep { $_->{to_user}->id == $requestee->id }
    sent_mails($bug, $requester);

  is(scalar @{$mail->{flag_events}}, 1,
    'requestee with no role on the bug gets the flag event');
  ok(scalar @{$mail->{new_comments}}, 'and the comments');
  ok(!@{$mail->{diffs}},              'but no diffs');

  $bug = new_bug(cc => [$requestee->login]);
  add_activity($bug, $next_flag_id++, '2000-01-01 00:00:10', '?', $requester,
    $requestee);
  ($mail) = grep { $_->{to_user}->id == $requestee->id }
    sent_mails($bug, $requester);

  ok(scalar @{$mail->{new_comments}},
    'requestee who is also CCed gets the comments too');
}

# A '?' with no requestee (e.g. approval-*) reaches the flag type cc_list
# only, including addresses with no account.
{
  my $bug = new_bug();
  add_activity($bug, $next_flag_id++, '2000-01-01 00:00:10', '?', $requester);
  my @events
    = Bugzilla::BugMail::_get_flag_mail_events($bug, $window_start, $window_end,
    {});
  my $sent = sent_to($bug, $requester);

  ok($sent->{$type_cc->login}, "a '?' with no requestee reaches the flag type cc_list");
  ok(!$sent->{$requester->login} && !$sent->{$requestee->login},
    'and no requestee or requester');

  my ($accounts, $raw)
    = Bugzilla::BugMail::_get_flag_type_cc($bug, \@events, {});
  ok($accounts->{$type_cc->id}, 'cc_list account is an account recipient');
  ok($raw->{$raw_cc},           'cc_list address with no account takes the raw mail path');
}

# The cc_list address with no account gets the new public comments, as with
# the old flag mail (e.g. the uplift request text on approval-* requests).
{
  my $bug = new_bug();
  $bug->add_comment('Uplift request: public reasons');
  $bug->add_comment('Uplift request: private reasons');
  $bug->update();

  # The test user can't mark comments private.
  $dbh->do('UPDATE longdescs SET isprivate = 1 WHERE bug_id = ? AND thetext = ?',
    undef, $bug->id, 'Uplift request: private reasons');
  $dbh->do('UPDATE bugs SET lastdiffed = ? WHERE bug_id = ?',
    undef, $window_start, $bug->id);
  add_activity($bug, $next_flag_id++, '2000-01-01 00:00:10', '?', $requester);

  my @raw;
  no warnings 'redefine';
  local *Bugzilla::BugMail::MessageToMTA = sub {
    push @raw, $_[0] if $_[0] =~ /^To: \Q$raw_cc\E$/m;
  };
  Bugzilla::BugMail::Send($bug->id, {changer => $requester});

  is(scalar @raw, 1, 'the cc_list address with no account is mailed');
  like($raw[0], qr/Uplift request: public reasons/, 'with the public comments');
  unlike($raw[0], qr/private reasons/, 'but not the private ones');
}

# A flag type edit queues one bugmail job per bug it touched.
{
  my @jobs;
  local Bugzilla->localconfig->param_override->{use_mailer_queue} = 1;

  # Loaded first, or loading it would replace the mock.
  require Bugzilla::JobQueue;
  no warnings 'redefine';
  local *Bugzilla::JobQueue::insert = sub { push @jobs, [@_[1, 2]] };
  Bugzilla::FlagType::_send_retargeted_bugmail([3, 5]);
  is_deeply(
    [map { [$_->[0], $_->[1]{bug_ids}] } @jobs],
    [['bug_mail_send', [3]], ['bug_mail_send', [5]]],
    'a flag type edit queues one bugmail job per bug'
  );
}

done_testing;
