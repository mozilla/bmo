#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 2086124: Hackbot comments carry a front matter block that links them to
# the run that wrote them. Comments are posted through the real REST API,
# in-process with Test::Mojo, then read back. The parser itself is covered
# without a DB in extensions/Hackbot/t/metadata.t.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla;
BEGIN { Bugzilla->extensions }
use Bugzilla::App ();
use Bugzilla::Bug;
use Bugzilla::Comment;
use Bugzilla::Config    qw(SetParam write_params);
use Bugzilla::Constants qw(bz_locations);
use Bugzilla::Extension::Hackbot::Config;
use Bugzilla::Extension::Push::Serialize;
use Bugzilla::Test::Util qw(create_user issue_api_key);
use Bugzilla::User;
use Bugzilla::User::Setting qw(clear_settings_cache);

use Email::MIME;
use Test::More;
use Test::Mojo;

# The app reads params from the database (through memcached) on every
# request, so set them there, and put them back afterwards. Bugmail is sent
# while the comment is posted and written to a file, so it can be read here.
my %original_params = map { $_ => Bugzilla->params->{$_} // '' }
  qw(hackbot_user use_mailer_queue mail_delivery_method edit_comments_admins_group);

sub set_params {
  my (%params) = @_;
  SetParam($_, $params{$_}) foreach keys %params;
  write_params();
  delete Bugzilla->request_cache->{hackbot_user_ids};
}

sub set_hackbot_user { set_params(hackbot_user => $_[0]) }

END { set_params(%original_params) if %original_params }
set_params(
  hackbot_user         => '',
  use_mailer_queue     => 0,
  mail_delivery_method => 'Test'
);

my $admin = Bugzilla::User->check({id => 1});
Bugzilla->set_user($admin);

# Reused on a rerun.
my $hackbot = create_user('hackbot@hackbot-metadata.test', '*');
my $other   = create_user('other@hackbot-metadata.test',   '*');

# Gets bugmail as text and HTML. Bugmail skips fake addresses (.bugs, .tld),
# so it has an ordinary one. Set up before the app runs any request: creating
# a user audits the change with remote_ip(), which wants a controller once a
# request has run.
my $watcher = create_user('watcher@hackbot-metadata.test', '*');
$watcher->settings->{email_format}->set('html');
clear_settings_cache($watcher->id);

my %api_key = map { $_->login => issue_api_key($_->login)->api_key } $admin,
  $hackbot, $other;

# One Test::Mojo for the whole file: building the app twice makes CGI::Compile
# die with "Tried to load admin.cgi more than once".
my $t = Test::Mojo->new('Bugzilla::App');

sub api_headers {
  my ($user) = @_;
  return {'X-Bugzilla-API-Key' => $api_key{$user->login}};
}

$t->post_ok(
  '/rest/bug' => api_headers($admin) => json => {
    product     => 'Firefox',
    component   => 'General',
    version     => 'Trunk',
    type        => 'defect',
    severity    => 'normal',
    op_sys      => 'Unspecified',
    platform    => 'Unspecified',
    summary     => 'Hackbot comment metadata',
    description => 'A bug for Hackbot to comment on',
  }
)->status_is(200, 'the bug is filed')
  or diag $t->tx->res->body;
my $bug_id = $t->tx->res->json->{id};

# Post a comment as $user and return it, read back from the database.
sub post_comment {
  my ($user, $text) = @_;
  $t->post_ok("/rest/bug/$bug_id/comment" => api_headers($user) => json =>
      {comment => $text, is_markdown => 1})->status_is(201, 'the comment is added')
    or diag $t->tx->res->body;
  return Bugzilla::Comment->new($t->tx->res->json->{id});
}

my $url = 'https://hackbot.example/runs/abc-123';
my $metadata
  = {run => 'abc-123', action => 'f00', agent => 'bug-fix', url => $url};
my $block = join("\n",
  '---',           'hackbot:',         '  run: abc-123',
  '  action: f00', '  agent: bug-fix', "  url: $url",
  '---',           '',                 '');
my $text = 'The failure is here.';

# hackbot_user is empty: the feature is off.
my $comment = post_comment($hackbot, "$block$text");
is($comment->body_full, "$block$text", 'off: the block stays in the text');
is($comment->hackbot,   undef,         'off: no metadata');

# hackbot_user is set.
set_hackbot_user($hackbot->login);

$comment = post_comment($hackbot, "$block$text");
is($comment->body_full,              $text, 'body_full hides the block');
is($comment->body_full({wrap => 1}), $text, '... when wrapped too');
is($comment->body, "$block$text",           'body keeps the stored text');
is_deeply($comment->hackbot, $metadata, 'hackbot returns the metadata');

$t->get_ok('/rest/bug/comment/' . $comment->id => api_headers($other))
  ->status_is(200)
  ->json_is('/comments/' . $comment->id . '/text',
  $text, 'REST text has no block')
  ->json_is(
  '/comments/' . $comment->id . '/raw_text',
  "$block$text",
  'REST raw_text keeps the stored text'
  );

# Webhook and Pulse payloads carry the text people read, as bugmail does.
my $push = Bugzilla::Extension::Push::Serialize->instance;
is($push->object_to_hash($comment, 1)->{body},
  $text, 'webhook and Pulse payloads have no block');

# Bugmail, in both formats, has the text and no block.
$t->put_ok("/rest/bug/$bug_id" => api_headers($admin) => json =>
    {cc => {add => [$watcher->login]}})->status_is(200, 'the watcher is CCd');

my $mail_file  = bz_locations()->{datadir} . '/mailer.testfile';
my $mail_start = -s $mail_file // 0;

# Bugmail covers the changes since the last mail, to the second, so a comment
# posted in the same second as the CC change could be left out.
sleep 1;
my $mail_text = 'Mail check: the failure is here.';
post_comment($hackbot, "$block$mail_text");

# The text/plain and text/html parts of the mail sent to the watcher, as
# [type, text] pairs.
my @parts;
if (open my $fh, '<', $mail_file) {
  seek $fh, $mail_start, 0;
  my $new_mail = do { local $/; <$fh> };
  foreach
    my $raw ($new_mail =~ /^-{10} begin message\n(.*?)^-{10} end message/msg)
  {
    my $email = Email::MIME->new($raw);
    next unless ($email->header('To') // '') eq $watcher->login;
    $email->walk_parts(sub {
      my ($part) = @_;
      my ($type) = $part->content_type =~ m{^(text/(?:plain|html))};
      push @parts, [$type, $part->body_str] if $type;
    });
  }
}
my @comment_parts = grep { $_->[1] =~ /\Q$mail_text\E/ } @parts;
is(scalar @comment_parts, 2, 'bugmail has the comment as text and HTML');
foreach my $part (@comment_parts) {
  unlike($part->[1], qr/hackbot:|run: abc-123/,
    "$part->[0] bugmail has no block");
}

# The text is parsed again after an edit.
is($comment->hackbot->{run}, 'abc-123', 'metadata before the edit');
(my $edited_block = $block) =~ s/abc-123/def-456/g;
$comment->update_text({
  text      => "${edited_block}Edited.",
  timestamp => Bugzilla->dbh->selectrow_array('SELECT NOW()'),
  is_hidden => 0,
});
is($comment->hackbot->{run}, 'def-456', 'an edited block is read again');
is($comment->body_full,      'Edited.', '... and hidden');
$comment->update_text({
  text      => 'Edited, with no block.',
  timestamp => Bugzilla->dbh->selectrow_array('SELECT NOW()'),
  is_hidden => 0,
});
is($comment->hackbot,   undef, 'a removed block leaves no metadata');
is($comment->body_full, 'Edited, with no block.', '... and the text is whole');

# Saving an inline edit returns the HTML the page shows, without the block.
# Admins edit other people's comments as edit-comments admins.
set_params(edit_comments_admins_group => 'admin');
my $edited   = post_comment($hackbot, "$block$text");
my $edit_url = '/rest/editcomments/comment/' . $edited->id;
$t->put_ok($edit_url => api_headers($admin) => json =>
    {new_comment => "${block}Edited text."})->status_is(200);
my $edit_html = $t->tx->res->json('/html');
unlike($edit_html, qr/hackbot:|run: abc-123/, 'the edit response has no block');
like($edit_html, qr/Edited text\./, '... and has the new text');

# Anyone can type the block.
my $forged = post_comment($other, "$block$text");
is($forged->body_full, "$block$text", 'another user: the block stays as text');
is($forged->hackbot,   undef,         'another user: no metadata');

my $plain = post_comment($hackbot, 'A plain comment');
is($plain->body_full, 'A plain comment', 'plain Hackbot comment is unchanged');
is($plain->hackbot,   undef, 'plain Hackbot comment has no metadata');

# Attachment comments are shown through their own template, which doesn't hide
# the block, so it isn't read there either.
$t->post_ok(
  "/rest/bug/$bug_id/attachment" => api_headers($hackbot) => json => {
    ids          => [$bug_id],
    data         => 'cGF0Y2g=',
    file_name    => 'fix.txt',
    summary      => 'fix',
    content_type => 'text/plain',
    comment      => "$block$text",
  }
)->status_is(201, 'the attachment is added')
  or diag $t->tx->res->body;
my $attachment_comment
  = Bugzilla::Bug->new($bug_id)->comments({order => 'oldest_to_newest'})->[-1];
ok($attachment_comment->type, 'the attachment has its own comment type');
is($attachment_comment->hackbot, undef,
  'an attachment comment has no metadata');

# The hackbot_user param.
my $check = \&Bugzilla::Extension::Hackbot::Config::check_hackbot_user;
is($check->(''),              '', 'an empty login is valid');
is($check->($hackbot->login), '', 'an existing login is valid');
like(
  $check->('nobody@hackbot-metadata.test'),
  qr/no user named/,
  'an unknown login is rejected'
);

done_testing;
