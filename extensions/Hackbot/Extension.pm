# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Extension);

use Bugzilla::Extension::Hackbot::Metadata qw(parse_front_matter);
use Bugzilla::User;

our $VERSION = '1';

BEGIN {
  no warnings 'redefine';
  *Bugzilla::Comment::hackbot = \&_comment_hackbot;
}

# The ID of the account named by the hackbot_user param, or 0 when it is unset
# or names nobody. Bugzilla::User::login_to_id doesn't cache a miss, and this
# runs for every comment that is read.
sub _hackbot_user_id {
  my $login = Bugzilla->params->{hackbot_user} or return 0;
  my $cache = Bugzilla->request_cache->{hackbot_user_ids} ||= {};
  return $cache->{$login} //= Bugzilla::User::login_to_id($login) || 0;
}

# Anyone can type a front matter block into a comment, so only the Hackbot
# account's comments are parsed. Returns the same list as parse_front_matter.
# A page reads each comment several times (header, badge, tags, text), so the
# result is kept on the comment for as long as its text is unchanged.
sub _parse_comment {
  my ($comment) = @_;
  my $user_id = _hackbot_user_id() or return;
  return unless ($comment->{who} // 0) == $user_id;

  my $body   = $comment->body;
  my $parsed = $comment->{hackbot_front_matter};
  if (!$parsed || $parsed->[0] ne $body) {
    $parsed = $comment->{hackbot_front_matter} = [$body, parse_front_matter($body)];
  }
  return @$parsed[1 .. $#$parsed];
}

sub _comment_hackbot {
  my ($comment) = @_;
  my ($metadata) = _parse_comment($comment);
  return $metadata;
}

sub comment_body_full {
  my ($self, $args) = @_;
  my (undef, $body) = _parse_comment($args->{comment});
  ${$args->{body}} = $body if defined $body;
}

sub config_add_panels {
  my ($self, $args) = @_;
  $args->{panel_modules}->{Hackbot} = 'Bugzilla::Extension::Hackbot::Config';
}

__PACKAGE__->NAME;
