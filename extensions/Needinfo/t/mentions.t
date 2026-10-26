#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use strict;
use warnings;
use lib qw( . lib local/lib/perl5 );

BEGIN {
  $ENV{LOG4PERL_CONFIG_FILE}     = 'log4perl-t.conf';
  $ENV{BUGZILLA_DISABLE_HOSTAGE} = 1;
}

use Bugzilla::Test::MockDB;
use Bugzilla::Test::MockParams;

use Test2::V0;

use Bugzilla;
BEGIN { Bugzilla->extensions }

my $extract = \&Bugzilla::Extension::Needinfo::_extract_mentions;

is([$extract->(undef)], [], 'undef text');
is([$extract->('no mentions here')], [], 'no mentions');
is([$extract->('@alice can you look?')], ['alice'], 'leading mention');
is([$extract->('thanks @alice, @bob and @carol.')],
  ['alice', 'bob', 'carol'], 'multiple mentions with punctuation');
is([$extract->('@alice and @Alice again @alice')], ['alice'],
  'duplicates collapsed case-insensitively');
is([$extract->('(@dk.l_x-y)')], ['dk.l_x-y'], 'nick symbols, parens');
is([$extract->('mail foo@example.com or a/@b or x.@y')], [],
  'emails and embedded @ ignored');
is([$extract->("> \@quoted said\n\@alice")], ['alice'], 'quoted lines ignored');
is([$extract->('run `@decorator` @alice')], ['alice'], 'inline code ignored');
is([$extract->('``@alice`` and `` a`@b ``')], [], 'double backtick code ignored');
is([$extract->("it's a ` stray\n\n\@alice `x`")],
  ['alice'], 'unclosed backtick does not span paragraphs');
is([$extract->('@foo|bar and |@alice|')], ['foo|bar', 'alice'],
  'pipe allowed in nick, trailing pipe stripped');
is(
  [$extract->("```perl\n\@inside\n```\n\@after")],
  ['after'], 'fenced code block ignored'
);
is([$extract->("~~~\n\@unclosed\n\@more")], [], 'unclosed fence runs to end');

# _process_mentions safeguards, using minimal stand-ins for users and bugs.
{

  package FakeUser;
  sub new          { my ($class, %args) = @_; bless {%args}, $class }
  sub id           { $_[0]{id} }
  sub nick         { $_[0]{nick} }
  sub name         { ucfirst $_[0]{nick} }
  sub login        { "$_[0]{nick}\@example.com" }
  sub in_group {
    my ($self, $group) = @_;
    return $self->{editbugs} if $group eq 'editbugs';
    return scalar grep { $_ eq $group } @{$self->{groups} || []};
  }
  sub is_insider   { $_[0]{insider} }
  sub can_see_bug  { $_[0]{sees_bug} // 1 }
  sub needinfo_blocked { 0 }

  package FakeBug;
  sub new {
    my ($class, $text, %type) = @_;
    bless {
      added_comments => [{thetext => $text}],
      groups         => [],
      cc             => [],
      needinfo       => [],
      type => bless({flags => [], multiplicable => 1, %type}, 'FakeType'),
    }, $class;
  }
  sub id                     {1}
  sub product_id             {1}
  sub flag_types             { [$_[0]{type}] }
  sub groups_in              { $_[0]{groups} }
  sub check_can_change_field { {allowed => 1} }
  sub add_cc {
    my ($self, $user) = @_;
    die "add_cc failed\n" if $user->{cc_fails};
    push @{$self->{cc}}, $user->nick;
  }

  # Like Bugzilla::Flag->set_flag, new flags are added to the type's list.
  sub set_flags {
    my ($self, undef, $new_flags) = @_;
    foreach my $flag (@$new_flags) {
      push @{$self->{needinfo}}, $flag->{requestee};
      push @{$self->{type}{flags}},
        bless({status => '?', requestee_id => 0}, 'FakeFlag');
    }
  }

  package FakeType;
  sub name             {'needinfo'}
  sub id               {1}
  sub is_multiplicable { $_[0]{multiplicable} }

  package FakeFlag;
  sub status       { $_[0]{status} }
  sub requestee_id { $_[0]{requestee_id} }

  package FakeCGI;
  sub param { @{$_[0]{names}} }

  package FakeGroup;
  sub new  { my ($class, $id, $name) = @_; bless {id => $id, name => $name}, $class }
  sub id   { $_[0]{id} }
  sub name { $_[0]{name} }
}

my %users = map { $_->nick => $_ } (
  FakeUser->new(id => 2, nick => 'alice'),
  FakeUser->new(id => 3, nick => 'bob', groups => ['core-security']),
  FakeUser->new(id => 4, nick => 'hidden', sees_bug => 0),
  FakeUser->new(id => 6, nick => 'boom', cc_fails => 1),
  map { FakeUser->new(id => 10 + $_, nick => "u$_") } 1 .. 12,
);
my $commenter = FakeUser->new(id => 1, nick => 'me', editbugs => 1);
my @looked_up;
my $usage_mode = Bugzilla::Constants::USAGE_MODE_BROWSER;
my %params = (needinfo_mentions_enabled => 1);
my $cgi = bless {names => ['id', 'comment']}, 'FakeCGI';

my $mock_bugzilla = mock 'Bugzilla' => (
  override => [
    user       => sub {$commenter},
    usage_mode => sub {$usage_mode},
    params     => sub { \%params },
    cgi        => sub {$cgi},
  ]
);
my $mock_ext = mock 'Bugzilla::Extension::Needinfo' => (
  override => [
    _users_for_mentions => sub {
      @looked_up = @_;
      return grep {defined} map { $users{$_} } @_;
    },
  ],
);

# The bug as it was before the update; it has no groups unless a test adds some.
my $old_bug = FakeBug->new('');
my $process = sub {
  Bugzilla::Extension::Needinfo::_process_mentions($_[0], $old_bug);
};

my $bug = FakeBug->new('@alice and @bob please look, cc @me');
$process->($bug);
is($bug->{cc}, ['alice', 'bob'], 'mentioned users CCd, self skipped');
is($bug->{needinfo}, ['alice@example.com', 'bob@example.com'],
  'mentioned users needinfod');

$bug = FakeBug->new('@hidden @alice');
$process->($bug);
is($bug->{cc}, ['alice'], 'user who cannot see the bug is not CCd');
is($bug->{needinfo}, ['alice@example.com'], '... nor needinfod');

$bug = FakeBug->new(join ' ', map {"\@u$_"} 1 .. 12);
$process->($bug);
is(\@looked_up, [map {"u$_"} 1 .. 10], 'only the first 10 nicknames are looked up');
is($bug->{cc},  [map {"u$_"} 1 .. 10], '... and only they are CCd');

$bug = FakeBug->new('@alice @bob', multiplicable => 0);
$process->($bug);
is($bug->{cc}, ['alice', 'bob'], 'non-multiplicable type: everyone CCd');
is($bug->{needinfo}, ['alice@example.com'], '... but only one needinfo');

$bug = FakeBug->new('@alice', multiplicable => 0);
push @{$bug->{type}{flags}}, bless({status => '?', requestee_id => 9}, 'FakeFlag');
$process->($bug);
is($bug->{cc},       ['alice'], 'non-multiplicable with existing flag: CCd');
is($bug->{needinfo}, [],        '... and no needinfo, instead of an error');

$bug = FakeBug->new('@alice');
push @{$bug->{type}{flags}}, bless({status => '?', requestee_id => 2}, 'FakeFlag');
$process->($bug);
is($bug->{needinfo}, [], 'no duplicate needinfo for a pending request');

$bug = FakeBug->new('@boom @alice');
ok(lives { $process->($bug) },
  'a failing CC (e.g. strict_isolation) does not throw');
is($bug->{cc},       ['alice'],             '... that user is skipped');
is($bug->{needinfo}, ['alice@example.com'], '... others still processed');

$bug = FakeBug->new('@alice @bob');
$bug->{added_comments}[0]{isprivate} = 1;
$users{bob}{insider} = 1;
$process->($bug);
is($bug->{cc},       ['bob'],             'private comment: only insiders are CCd');
is($bug->{needinfo}, ['bob@example.com'], '... and needinfod');
$users{bob}{insider} = 0;

my $security = FakeGroup->new(1, 'core-security');
$bug = FakeBug->new('@alice @bob');
$bug->{groups} = [$security];
$process->($bug);
is($bug->{cc}, ['bob'], 'group added in this update: only its members are CCd');
is($bug->{needinfo}, ['bob@example.com'], '... and needinfod');

$old_bug->{groups} = [$security];
$bug = FakeBug->new('@alice');
$bug->{groups} = [$security];
$process->($bug);
is($bug->{cc}, ['alice'], 'existing group is left to can_see_bug');
$old_bug->{groups} = [];

$usage_mode = Bugzilla::Constants::USAGE_MODE_REST;
@looked_up = ();
$bug = FakeBug->new('@alice');
$process->($bug);
is(\@looked_up,      [], 'no lookup for comments made through the API');
is($bug->{cc},       [], 'no CC for comments made through the API');
$usage_mode = Bugzilla::Constants::USAGE_MODE_BROWSER;

$cgi->{names} = ['id_12', 'id_13', 'comment', 'dontchange'];
@looked_up = ();
$bug = FakeBug->new('@alice');
$process->($bug);
is(\@looked_up, [], 'no lookup in a mass edit');
is($bug->{cc},  [], 'no CC in a mass edit');
$cgi->{names} = ['id', 'comment'];

$params{needinfo_mentions_enabled} = 0;
@looked_up = ();
$bug = FakeBug->new('@alice');
$process->($bug);
is(\@looked_up, [], 'no lookup when needinfo_mentions_enabled is off');
is($bug->{cc},  [], 'no CC when needinfo_mentions_enabled is off');
$params{needinfo_mentions_enabled} = 1;

# The comment preview lists the users that saving would CC and needinfo.
my $preview_bug = FakeBug->new('');
my $render = sub {
  my ($params) = @_;
  my $result = {html => ''};
  Bugzilla::Extension::Needinfo->webservice_bug_render_comment({
    bug    => $params->{id} ? $preview_bug : undef,
    params => $params,
    result => $result
  });
  return $result;
};

is(
  $render->({text => '@alice @hidden @me', id => 1, include_mentions => 1})
    ->{mentions},
  [{nick => 'alice', name => 'Alice'}],
  'preview lists the users a save would notify'
);
is($preview_bug->{cc}, [], '... without changing the bug');

$users{bob}{insider} = 1;
is(
  $render->({
    text               => '@alice @bob',
    id                 => 1,
    include_mentions   => 1,
    mention_is_private => 1
  })->{mentions},
  [{nick => 'bob', name => 'Bob'}],
  'preview of a private comment lists only insiders'
);
$users{bob}{insider} = 0;

ok(!exists $render->({text => '@alice', include_mentions => 1})->{mentions},
  'no mentions without a bug (e.g. a new bug)');
ok(!exists $render->({text => '@alice', id => 1})->{mentions},
  'no mentions unless asked for (e.g. an edited comment)');

$params{needinfo_mentions_enabled} = 0;
is($render->({text => '@alice', id => 1, include_mentions => 1})->{mentions},
  [], 'preview lists nobody when needinfo_mentions_enabled is off');
$params{needinfo_mentions_enabled} = 1;

$commenter->{editbugs} = 0;
@looked_up = ();
$bug = FakeBug->new('@alice');
$process->($bug);
is(\@looked_up,       [], 'no lookup for commenters without editbugs');
is($bug->{cc},        [], 'no CC for commenters without editbugs');
is($bug->{needinfo},  [], 'no needinfo for commenters without editbugs');

done_testing;
