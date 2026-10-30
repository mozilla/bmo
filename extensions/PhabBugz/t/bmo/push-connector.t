#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Push::Connector::Phabricator: bug changes pushed to the revisions attached
# to the bug only edit a revision when something on it actually changes.

use 5.10.1;
use strict;
use warnings;
use lib qw(. lib local/lib/perl5);
use FindBin;
use lib "$FindBin::Bin/lib";

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test::More;

use Bugzilla::Extension::PhabBugz::Util qw(
  create_revision_attachment
  get_bug_role_phids
);
use Bugzilla::Extension::Push::Connector::Phabricator;
use PhabTest::Conduit qw(:all);
use PhabTest::Env;
use PhabTest::Fixtures qw(:all);

my $env     = PhabTest::Env->new;
my $conduit = $env->conduit;

my $admin_phab  = $env->link_user($env->admin);
my $author      = $env->bmo_user('author');
my $author_phab = $env->link_user($author);
my $alice       = $env->bmo_user('alice');
my $alice_phab  = $env->link_user($alice);

my ($timestamp) = Bugzilla->dbh->selectrow_array('SELECT NOW()');

my $connector = Bugzilla::Extension::Push::Connector::Phabricator->new;

# A bug with one revision attached, subscribed to by `subscribers`. The
# revision is attached while the bug is still public, then `groups` are
# added to make it private.
sub bug_with_revision {
  my (%args)   = @_;
  my $bug      = $env->bug(%{$args{bug} // {}});
  my $revision = $conduit->load_revision(revision_obj(
    bug_id      => $bug->id,
    author_phid => $author_phab->{phid},
    subscribers => $args{subscribers} // [],
  ));
  create_revision_attachment($bug, $revision, $timestamp, $author);
  $bug->update($timestamp);

  Bugzilla->dbh->do('INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)',
    undef, $bug->id, $_->id)
    foreach @{$args{groups} // []};

  return Bugzilla::Bug->new($bug->id);
}

sub send_change {
  my ($bug, $fields) = @_;
  my $message = PushMessage->new("bug.modify:$fields",
    {event => {target => 'bug'}, bug => {id => $bug->id}});
  $conduit->reset_calls;
  $connector->send($message);
  return [$conduit->calls('differential.revision.edit')];
}

# A CC change on a public bug has nothing to push
{
  my $bug = bug_with_revision(bug => {cc => [$alice]});
  is_deeply(send_change($bug, 'cc'),
    [], 'no revision edit for a cc change on a public bug');
}

# A private bug whose revision already has the bug roles as subscribers
{
  my $group = $env->bug_group('grp');
  my $bug   = bug_with_revision(
    bug         => {cc => [$alice]},
    groups      => [$group],
    subscribers => [$alice_phab->{phid}, $admin_phab->{phid}],
  );
  is_deeply(
    [sort @{get_bug_role_phids($bug)}],
    [sort $admin_phab->{phid}, $alice_phab->{phid}],
    'bug roles match the revision subscribers'
  );
  is_deeply(send_change($bug, 'cc'),
    [], 'no revision edit when the subscribers already match');
}

# A private bug whose revision is missing a bug role as a subscriber
{
  my $group = $env->bug_group('grp');
  my $bug   = bug_with_revision(
    bug         => {cc => [$alice]},
    groups      => [$group],
    subscribers => [$admin_phab->{phid}],
  );
  my $edits = send_change($bug, 'cc');
  is(scalar @$edits, 1, 'one revision edit');
  is_deeply([map { $_->{type} } @{$edits->[0]{transactions}}],
    ['subscribers.set'], 'only the subscribers are set');
  is_deeply(
    [sort @{$edits->[0]{transactions}[0]{value}}],
    [sort $admin_phab->{phid}, $alice_phab->{phid}],
    'subscribers set to the bug roles'
  );
}

$env->finish;
done_testing;

package PushMessage;

sub new {
  my ($class, $routing_key, $payload) = @_;
  return bless {routing_key => $routing_key, payload => $payload}, $class;
}
sub routing_key     { $_[0]->{routing_key} }
sub payload_decoded { $_[0]->{payload} }
