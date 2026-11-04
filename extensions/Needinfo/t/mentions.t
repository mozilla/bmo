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
  sub can_see_product  { $_[0]{sees_product} // 1 }
  sub needinfo_blocked { $_[0]{blocked}      // 0 }
  sub can_set_flag     { $_[0]{can_set}      // 1 }
  sub can_change_flag  { $_[0]{can_request}  // 1 }

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
  sub is_requestable   { $_[0]{requestable}  // 1 }
  sub is_requesteeble  { $_[0]{requesteeble} // 1 }

  package FakeFlag;
  sub status       { $_[0]{status} }
  sub requestee_id { $_[0]{requestee_id} }

  package FakeCGI;
  sub param { @{$_[0]{names}} }

  package FakeGroup;
  sub new  { my ($class, $id, $name) = @_; bless {id => $id, name => $name}, $class }
  sub id   { $_[0]{id} }
  sub name { $_[0]{name} }

  package FakeProduct;
  sub new {
    my ($class, %args) = @_;
    bless {valid => [], mandatory => [], %args}, $class;
  }
  sub id               {1}
  sub name             {'Fake Product'}
  sub groups_valid     { $_[0]{valid} }
  sub groups_mandatory { $_[0]{mandatory} }
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

$users{bob}{can_set} = 0;
$bug = FakeBug->new('@alice @bob');
$process->($bug);
is($bug->{cc},       ['alice', 'bob'], 'requestee without flag privs: CCd');
is($bug->{needinfo}, ['alice@example.com'], '... but not needinfod');
delete $users{bob}{can_set};

$commenter->{can_request} = 0;
$bug = FakeBug->new('@alice');
$process->($bug);
is($bug->{cc},       ['alice'], 'commenter cannot request needinfo: CCd');
is($bug->{needinfo}, [],        '... but not needinfod');
delete $commenter->{can_request};

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
  [{nick => 'alice', name => 'Alice', needinfo => 1}],
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
  [{nick => 'bob', name => 'Bob', needinfo => 1}],
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

# The live mention warning (POST /rest/needinfo/mentions) tells needinfo from
# CC-only mentions.
my $effects = \&Bugzilla::Extension::Needinfo::mention_effects;

$preview_bug = FakeBug->new('');
push @{$preview_bug->{type}{flags}},
  bless({status => '?', requestee_id => 3}, 'FakeFlag');
$users{alice}{blocked} = 1;
is(
  $effects->({thetext => '@alice @bob @u1 @me'}, {bug => $preview_bug}),
  [
    {nick => 'alice', name => 'Alice', needinfo => 0},
    {nick => 'bob',   name => 'Bob',   needinfo => 0},
    {nick => 'u1',    name => 'U1',    needinfo => 1},
  ],
  'warning: blocked and already needinfod users are only CCd'
);
$users{alice}{blocked} = 0;
is($preview_bug->{cc}, [], '... without changing the bug');

$preview_bug = FakeBug->new('', multiplicable => 0);
push @{$preview_bug->{type}{flags}},
  bless({status => '?', requestee_id => 9}, 'FakeFlag');
is(
  $effects->({thetext => '@alice'}, {bug => $preview_bug}),
  [{nick => 'alice', name => 'Alice', needinfo => 0}],
  'warning: non-multiplicable type with a flag only CCs'
);

is(
  $effects->(
    {thetext => '@alice @bob'},
    {bug     => FakeBug->new('', multiplicable => 0)}
  ),
  [
    {nick => 'alice', name => 'Alice', needinfo => 1},
    {nick => 'bob',   name => 'Bob',   needinfo => 0},
  ],
  'warning: non-multiplicable type without a flag only needinfos the first'
);

$preview_bug = FakeBug->new('');
$users{bob}{can_set} = 0;
is(
  $effects->({thetext => '@alice @bob'}, {bug => $preview_bug}),
  [
    {nick => 'alice', name => 'Alice', needinfo => 1},
    {nick => 'bob',   name => 'Bob',   needinfo => 0},
  ],
  'warning: a requestee without flag privs is only CCd'
);
delete $users{bob}{can_set};
is($preview_bug->{type}{flags}, [], '... and the bug\'s flags are unchanged');

$commenter->{can_request} = 0;
is(
  $effects->({thetext => '@alice'}, {bug => FakeBug->new('')}),
  [{nick => 'alice', name => 'Alice', needinfo => 0}],
  'warning: no needinfo when the commenter cannot request it'
);
delete $commenter->{can_request};

foreach my $field (qw(requestable requesteeble)) {
  is(
    $effects->({thetext => '@alice'}, {bug => FakeBug->new('', $field => 0)}),
    [{nick => 'alice', name => 'Alice', needinfo => 0}],
    "warning: no needinfo when the type is not $field"
  );
}

is($effects->({thetext => "`\@alice`\n> \@bob"}, {bug => FakeBug->new('')}),
  [], 'warning: mentions in code and quotes are ignored');

{
  my $mock_bug_type = mock 'FakeBug' =>
    (override => [check_can_change_field => sub { {allowed => 0} }]);
  is(
    $effects->({thetext => '@alice'}, {bug => FakeBug->new('')}),
    [{nick => 'alice', name => 'Alice', needinfo => 0}],
    'warning: no needinfo when the user cannot change flags on the bug'
  );
}

# Saving a new bug doesn't process mentions yet (bug 2087012), so the warning
# on the bug entry form lists nobody.
is($effects->({thetext => '@alice'}, {product => FakeProduct->new}),
  [], 'new bug: nobody until saving a new bug processes mentions');

# The prediction for the initial comment of a bug being filed, ready for when
# it does: there is no bug to check visibility against, so the product and
# the new bug's groups are used.
my $new_bug_effects = \&Bugzilla::Extension::Needinfo::new_bug_mention_effects;
my $needinfo_types  = [bless({multiplicable => 1}, 'FakeType')];
my %type_criteria;
my $mock_flagtype = mock 'Bugzilla::FlagType' => (
  override => [
    match => sub { %type_criteria = %{$_[0]}; return $needinfo_types },
  ],
);
my $product = FakeProduct->new(valid => [$security]);

is(
  $new_bug_effects->({thetext => '@alice @hidden @me'}, {product => $product}),
  [
    {nick => 'alice',  name => 'Alice',  needinfo => 1},
    {nick => 'hidden', name => 'Hidden', needinfo => 1},
  ],
  'new bug: users who can see the product are needinfod'
);
is($type_criteria{name}, 'needinfo',    '... using the needinfo flag type');
is($type_criteria{component_id}, undef, '... of the product when no component');

$users{alice}{sees_product} = 0;
is(
  $new_bug_effects->({thetext => '@alice @bob'}, {product => $product}),
  [{nick => 'bob', name => 'Bob', needinfo => 1}],
  'new bug: users who cannot see the product are skipped'
);
delete $users{alice}{sees_product};

is(
  $new_bug_effects->(
    {thetext => '@alice @bob'},
    {product => $product, groups => ['core-security', 'not-valid-here']}
  ),
  [{nick => 'bob', name => 'Bob', needinfo => 1}],
  'new bug: selected groups limit who is mentioned, invalid ones ignored'
);

is(
  $new_bug_effects->(
    {thetext => '@alice @bob'},
    {product => FakeProduct->new(mandatory => [$security])}
  ),
  [{nick => 'bob', name => 'Bob', needinfo => 1}],
  'new bug: mandatory product groups limit who is mentioned'
);

is(
  $new_bug_effects->(
    {thetext => '@alice'},
    {product => $product, component => FakeGroup->new(7, 'General')}
  ),
  [{nick => 'alice', name => 'Alice', needinfo => 1}],
  'new bug with a component'
);
is($type_criteria{component_id}, 7, '... uses that component\'s flag types');

$users{alice}{blocked} = 1;
is(
  $new_bug_effects->({thetext => '@alice'}, {product => $product}),
  [{nick => 'alice', name => 'Alice', needinfo => 0}],
  'new bug: a user blocking needinfo is only CCd'
);
$users{alice}{blocked} = 0;

$needinfo_types = [];
is(
  $new_bug_effects->({thetext => '@alice'}, {product => $product}),
  [{nick => 'alice', name => 'Alice', needinfo => 0}],
  'new bug: no needinfo without a needinfo flag type'
);
$mock_flagtype = undef;

$params{needinfo_mentions_enabled} = 0;
is($new_bug_effects->({thetext => '@alice'}, {product => $product}),
  [], 'new bug: nobody when needinfo_mentions_enabled is off');
$params{needinfo_mentions_enabled} = 1;

$commenter->{editbugs} = 0;
is($new_bug_effects->({thetext => '@alice'}, {product => $product}),
  [], 'new bug: nobody for commenters without editbugs');
is($effects->({thetext => '@alice'}, {bug => FakeBug->new('')}),
  [], 'warning: nobody for commenters without editbugs');

@looked_up = ();
$bug = FakeBug->new('@alice');
$process->($bug);
is(\@looked_up,       [], 'no lookup for commenters without editbugs');
is($bug->{cc},        [], 'no CC for commenters without editbugs');
is($bug->{needinfo},  [], 'no needinfo for commenters without editbugs');

done_testing;
