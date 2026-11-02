#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use strict;
use warnings;
use 5.10.1;

use lib qw(. lib local/lib/perl5);

use Bugzilla;
use Bugzilla::BugMail;
BEGIN { Bugzilla->extensions() }

use Bugzilla::Comment;
use Bugzilla::Constants;
use Bugzilla::User;

use List::Util qw(none);

Bugzilla->usage_mode(USAGE_MODE_CMDLINE);

# Set current user to automation
my $auto_user = Bugzilla::User->check({name => 'github-automation@bmo.tld'});
$auto_user->{groups}       = [Bugzilla::Group->get_all];
$auto_user->{bless_groups} = [Bugzilla::Group->get_all];
Bugzilla->set_user($auto_user);

# Find all spam comment entries made before a specific amount of time
my $cutoff_time = DateTime->now(time_zone => 'UTC')->subtract(minutes => 30)
  ->strftime('%Y-%m-%d %T');

my $dbh = Bugzilla->dbh;

my $query = q{
  SELECT comment_id 
    FROM antispam_comment_cleanup
   WHERE comment_ts <= ?
  ORDER BY comment_id};
my $comment_ids = $dbh->selectcol_arrayref($query, undef, $cutoff_time);

foreach my $comment_id (@{$comment_ids}) {
  my $comment = Bugzilla::Comment->new($comment_id);
  my $bug     = $comment->bug;

  # Clear a needinfo that was set on a comment tagged as spam
  my @clear_flags = ();
  foreach my $flag (@{$bug->flags}) {
    next
      if $flag->type->name ne 'needinfo'
      && $flag->status ne '?'
      && $flag->requestee_id != $comment->author->id
      && $flag->modification_date eq $comment->creation_ts;
    push @clear_flags, {id => $flag->id, status => 'X'};
  }
  if (@clear_flags) {
    $bug->set_flags(\@clear_flags, []);
    $bug->update;

    # Flag mail is part of bugmail, so the requesters are told now rather
    # than with the bug's next change.
    Bugzilla::BugMail::Send($bug->id, {changer => $auto_user});
  }

  # Lastly we need to remove the entry from the cleanup queue
  $dbh->do('DELETE FROM antispam_comment_cleanup WHERE comment_id = ?',
    undef, $comment_id);
}
