# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
package Bugzilla::Extension::Needinfo;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Extension);

use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Flag;
use Bugzilla::FlagType;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::User::Setting;

use List::Util qw(all);

our $VERSION = '0.01';

use constant MAX_MENTIONS => 10;

BEGIN {
  *Bugzilla::User::needinfo_blocked = \&_user_needinfo_blocked;
}

sub _user_needinfo_blocked {
  my ($requestee) = @_;
  my $setting = $requestee->settings->{block_needinfo} or return 0;

  return 1 if $setting->{value} eq 'on';
  return 0 unless $setting->{value} eq 'editbugs';

  # Never block someone from needinfo'ing themselves.
  return 0 if Bugzilla->user->id == $requestee->id;

  return Bugzilla->user->in_group('editbugs') ? 0 : 1;
}

sub install_update_db {
  my ($self, $args) = @_;
  my $dbh = Bugzilla->dbh;

  if (@{Bugzilla::FlagType::match({name => 'needinfo'})}) {
    return;
  }

  print "Creating needinfo flag ... "
    . "enable the Needinfo feature by editing the flag's properties.\n";

  # inclusions 0:0 maps to __ANY__ : __ANY__ in the UI,
  # meaning needinfo is enabled for all products and components by default
  my $flagtype = Bugzilla::FlagType->create({
    name => 'needinfo',
    description =>
      "Set this flag when the bug is in need of additional information",
    target_type      => 'bug',
    cc_list          => '',
    sortkey          => 1,
    is_active        => 1,
    is_requestable   => 1,
    is_requesteeble  => 1,
    is_multiplicable => 1,
    request_group    => '',
    grant_group      => '',
    inclusions       => ['0:0'],
    exclusions       => [],
  });
}

sub install_before_final_checks {
  my ($self, $args) = @_;
  add_setting({
    name        => 'block_needinfo',
    options     => ['on', 'editbugs', 'off'],
    default     => 'off',
    category    => 'Reviews and Needinfo',

    # The setting predates the 'editbugs' option, so force add_setting to
    # rebuild it. remove_setting only drops user choices outside the new
    # option list, so existing 'on'/'off' preferences survive.
    force_check => 1,
  });
}

sub bug_end_of_create {
  my ($self, $args) = @_;
  my $params = Bugzilla->input_params;

  _keep_description_for_mentions($args->{bug});

  return unless $params->{needinfo_from};

  # Add extra params
  $params->{needinfo} = 1;
  $params->{needinfo_role} = 'other';

  # Do the rest
  $self->bug_start_of_update($args);
}

sub bug_start_of_update {
  my ($self, $args) = @_;
  _process_needinfo_params($args);

  # Runs after the explicit needinfo handling so that the duplicate check
  # sees any flags that were just requested through the form.
  _process_mentions($args->{bug}, $args->{old_bug}) if $args->{old_bug};
}

# Clear the needinfo? flag if comment is being given by
# requestee or someone used the override flag.
sub _process_needinfo_params {
  my ($args) = @_;
  my $bug     = $args->{bug};
  my $old_bug = $args->{old_bug};

  my $user   = Bugzilla->user;
  my $cgi    = Bugzilla->cgi;
  my $params = Bugzilla->input_params;

  if ($params->{needinfo}) {

    # do a match if applicable
    Bugzilla::User::match_field({'needinfo_from' => {'type' => 'multi'}});
  }

  # Set needinfo_done param to true so as to not loop back here
  return if $params->{needinfo_done};
  $params->{needinfo_done} = 1;
  Bugzilla->input_params($params);

  my $add_needinfo  = delete $params->{needinfo};
  my $needinfo_type = delete $params->{needinfo_type} // '';
  my $needinfo_from = delete $params->{needinfo_from};
  my $needinfo_role = delete $params->{needinfo_role};
  my $is_redirect   = $needinfo_type eq 'redirect_to' ? 1 : 0;
  my $is_private    = $params->{'comment_is_private'};

  my @needinfo_overrides;
  foreach my $key (grep(/^needinfo_override_/, keys %$params)) {
    my ($id) = $key =~ /(\d+)$/;

    # Should always be true if key exists (checkbox) but better to be sure
    push(@needinfo_overrides, $id) if $id && $params->{$key};
  }

  # Set the needinfo flag if user is requesting more information
  my @new_flags;
  my $needinfo_requestee;

  if ($add_needinfo) {
    foreach my $type (@{$bug->flag_types}) {
      next if $type->name ne 'needinfo';
      my %requestees;

      # Allow anyone to be the requestee
      if (!$needinfo_role) {
        $requestees{'anyone'} = 1;
      }

      # Use assigned_to as requestee
      elsif ($needinfo_role eq 'assigned_to') {
        $requestees{$bug->assigned_to->login} = 1;
      }

      # Use reporter as requestee
      elsif ($needinfo_role eq 'reporter') {
        $requestees{$bug->reporter->login} = 1;
      }

      # Use qa_contact as requestee
      elsif ($needinfo_role eq 'qa_contact') {
        $requestees{$bug->qa_contact->login} = 1;
      }

      # Use current user as requestee
      elsif ($needinfo_role eq 'user') {
        $requestees{$user->login} = 1;
      }
      elsif ($needinfo_role eq 'triage_owner') {
        if ($bug->component_obj->triage_owner_id) {
          $requestees{$bug->component_obj->triage_owner->login} = 1;
        }
      }

      # Use user specified requestee
      elsif ($needinfo_role eq 'other' && $needinfo_from) {
        my @needinfo_from_list
          = ref $needinfo_from ? @$needinfo_from : ($needinfo_from);
        foreach my $requestee (@needinfo_from_list) {
          my $requestee_obj = Bugzilla::User->check($requestee);
          $requestees{$requestee_obj->login} = 1;
        }
      }

      # Requestee is a mentor
      elsif ($needinfo_role
        && Bugzilla::User->check({name => $needinfo_role, cache => 1}))
      {
        $requestees{$needinfo_role} = 1;
      }

      # Find out if the requestee has already been used and skip if so
      my $requestee_found;
      foreach my $flag (@{$type->{flags}}) {
        if (!$flag->requestee && $requestees{'anyone'}) {
          delete $requestees{'anyone'};
        }
        if ($flag->requestee && $requestees{$flag->requestee->login}) {
          delete $requestees{$flag->requestee->login};
        }
      }

      foreach my $requestee (keys %requestees) {
        my $needinfo_flag = {type_id => $type->id, status => '?'};
        if ($requestee ne 'anyone') {
          _check_requestee($requestee);
          $needinfo_flag->{requestee} = $requestee;
          my $requestee_obj = Bugzilla::User->check($requestee);
          if (!$requestee_obj->can_see_bug($bug->id)) {
            $bug->add_cc($requestee_obj);
          }
        }
        push(@new_flags, $needinfo_flag);
      }
    }
  }

  my @flags;
  foreach my $flag (@{$bug->flags}) {
    next if $flag->type->name ne 'needinfo';

    # Clear if somehow the flag has been set to +/-
    # or if the "clear needinfo" override checkbox is selected
    if ($flag->status ne '?' or grep { $_ == $flag->id } @needinfo_overrides) {
      push(@flags, {id => $flag->id, status => 'X'});
    }
  }

  if ($is_redirect && scalar(@new_flags) == 1) {

    # Find the current user's needinfo request
    foreach my $flag (@{$bug->flags}) {
      next
        unless $flag->type->name eq 'needinfo'
        && $flag->requestee
        && $flag->requestee->id == $user->id;

      # Setting the id on new_flag updates the existing flag instead of
      # creating a new one.
      $new_flags[0]->{id} = $flag->id;
      last;
    }
  }

  if (@flags || @new_flags) {
    $bug->set_flags(\@flags, \@new_flags);
  }
}

# Returns the unique nicknames @mentioned in a comment, in order of first
# appearance. Mentions inside quoted lines (> ...) and code are ignored, as
# are email addresses (the @ must not follow a word character).
sub _extract_mentions {
  my ($text) = @_;
  return () unless defined $text;

  $text =~ s/^[ \t]*(`{3,}|~{3,}).*?(?:^[ \t]*\1[^\n]*$|\z)//msg;
  # A code span closes on a backtick run of the same length, within a paragraph.
  $text = join "\n\n",
    map { s/(?<!`)(`+)(?!`).+?(?<!`)\1(?!`)//sgr } split /\n[ \t]*\n/, $text;
  $text =~ s/^[ \t]*>.*$//mg;

  my (@nicks, %seen);
  # Same character set as extract_nicks in Bugzilla/Util.pm.
  while ($text =~ /(?<![\w@.\/-])@([\p{IsAlnum}|._-]+)/g) {
    (my $nick = $1) =~ s/[.|]+$//;
    next if $nick eq '' || $seen{lc $nick}++;
    push @nicks, $nick;
  }
  return @nicks;
}

# Maps nicknames to enabled user accounts. A nickname shared by more than one
# account is ambiguous and dropped rather than guessed at.
sub _users_for_mentions {
  my (@nicks) = @_;
  return () unless @nicks;

  my $dbh  = Bugzilla->dbh;
  my $rows = $dbh->selectall_arrayref(
    'SELECT userid, nickname FROM profiles WHERE is_enabled = 1 AND '
      . $dbh->sql_in('nickname', [map { $dbh->quote($_) } @nicks]));

  my %ids_by_nick;
  push @{$ids_by_nick{lc $_->[1]}}, $_->[0] foreach @$rows;
  my @ids = map { $_->[0] } grep { @$_ == 1 } values %ids_by_nick;
  return @{Bugzilla::User->new_from_list(\@ids)};
}

# Returns the users a set of new comments ({thetext, isprivate} hashes) on
# $bug would CC and needinfo, applying the safeguards described above
# _process_mentions. Shared by saving, the comment preview and the live
# mention warning so they can't disagree with what actually happens. $old_bug
# is only passed when saving, to account for groups added in the same update.
sub _mentioned_users {
  my ($bug, $comments, $old_bug) = @_;

  # can_see_bug reads the groups stored in the database, which don't yet
  # include groups added by this update, so check those separately. Only
  # looked up once a mention has passed the cheaper checks.
  my $added_groups;
  my $can_see = sub {
    my ($mentioned) = @_;
    return 0 unless $mentioned->can_see_bug($bug->id);
    $added_groups //= _added_groups($bug, $old_bug);
    return all { $mentioned->in_group($_) } @$added_groups;
  };

  return _filter_mentioned_users($bug->product_id, $comments, $can_see);
}

# Like _mentioned_users, for a bug that is still being filed in $product with
# the bug groups named in $group_names. Used by the live mention warning on
# the bug entry form, where there is no bug to check visibility against yet:
# the mentioned user has to be able to see the product and be in every group
# the new bug will be in (the selected ones plus the product's mandatory ones).
sub _mentioned_users_for_new_bug {
  my ($product, $group_names, $comments) = @_;

  my %valid = map { $_->name => 1 } @{$product->groups_valid};
  my %groups = map { $_ => 1 } (grep { $valid{$_} } @{$group_names || []}),
    (map { $_->name } @{$product->groups_mandatory});

  my $can_see = sub {
    my ($mentioned) = @_;
    return $mentioned->can_see_product($product->name)
      && all { $mentioned->in_group($_) } keys %groups;
  };

  return _filter_mentioned_users($product->id, $comments, $can_see);
}

sub _added_groups {
  my ($bug, $old_bug) = @_;
  return [] unless $old_bug;
  my %old_groups = map { $_->id => 1 } @{$old_bug->groups_in};
  return [map { $_->name } grep { !$old_groups{$_->id} } @{$bug->groups_in}];
}

# The checks shared by _mentioned_users and _mentioned_users_for_new_bug.
# $can_see is called with each mentioned user and returns whether they can see
# the bug.
sub _filter_mentioned_users {
  my ($product_id, $comments, $can_see) = @_;
  return () unless Bugzilla->params->{needinfo_mentions_enabled};

  # Lowercased nick => true if mentioned in at least one public comment.
  my %public;

  # The first MAX_MENTIONS distinct lowercased nicks, in order of appearance.
  my @nicks;

  foreach my $comment (@$comments) {
    foreach my $nick (map {lc} _extract_mentions($comment->{thetext})) {
      push @nicks, $nick if !exists $public{$nick} && @nicks < MAX_MENTIONS;
      $public{$nick} ||= !$comment->{isprivate};
    }
  }
  return () unless @nicks;

  # Checked after parsing so updates without mentions skip the group lookup.
  my $user = Bugzilla->user;
  return () unless $user->in_group('editbugs', $product_id);

  return grep {
    my $mentioned = $_;
         $mentioned->id != $user->id
      && ($public{lc $mentioned->nick} || $mentioned->is_insider)
      && $can_see->($mentioned)
  } _users_for_mentions(@nicks);
}

# GitHub-style mentions: each @nickname in a new comment, or in the description
# of a new bug, is CC'd and gets a needinfo request. Mentions never block the
# comment from being saved; anyone who can't be needinfo'd (blocked, already
# asked, no permission, or the needinfo type isn't multiplicable and a flag
# exists) is only CC'd.
#
# Safeguards against misuse:
# - only comments made in the web UI count, so bots and API clients posting
#   commit messages, code or logs can't CC people by accident
# - only editbugs users can trigger mentions; for everyone else they are text
# - only the first MAX_MENTIONS distinct nicknames per update are processed
# - mass edits are skipped, since the same comment lands on every bug and
#   would CC and needinfo each mentioned user once per bug
# - users who can't already see the bug are skipped, so a mention (or a typo,
#   or a squatted nickname) can never grant access to a restricted bug; that
#   includes groups being added to the bug in this same update
# - admins can switch the whole feature off with the needinfo_mentions_enabled
#   param
sub _process_mentions {
  my ($bug, $old_bug) = @_;

  # The description of a new bug, kept by bug_end_of_create. Taken before the
  # checks below so that only the first update after creation considers it.
  my $description = delete $bug->{needinfo_description};

  return unless Bugzilla->usage_mode == USAGE_MODE_BROWSER;
  return if _is_mass_edit();

  my @comments  = (($description // ()), @{$bug->{added_comments} || []});
  my @mentioned = _mentioned_users($bug, \@comments, $old_bug);
  return unless @mentioned;

  my $type = _needinfo_type($bug);

  # A failure for one user (e.g. add_cc's strict_isolation check) skips that
  # user rather than rolling back the whole update. Throw*Error only dies
  # (instead of printing an error page and exiting) in ERROR_MODE_DIE, so the
  # eval can catch it.
  local Bugzilla->request_cache->{error_mode} = ERROR_MODE_DIE;
  local $@;
  foreach my $mentioned (@mentioned) {
    eval { _cc_and_needinfo($bug, $mentioned, $type); 1 }
      or WARN('Skipped mention of ' . $mentioned->login . " on bug "
        . $bug->id . ": $@");
  }
}

# Comment 0 is inserted by Bug->create itself rather than through add_comment,
# so it never appears in added_comments. Keep it on the bug for
# _process_mentions, which handles it in the update that follows creation
# (post_bug.cgi always updates the new bug to set the flags from the form).
# Waiting for that update means the bug and its groups are committed, and that
# needinfo flags requested on the form are known, so a user both mentioned and
# needinfo'd explicitly gets only one request.
sub _keep_description_for_mentions {
  my ($bug) = @_;
  return unless Bugzilla->params->{needinfo_mentions_enabled};
  return unless Bugzilla->usage_mode == USAGE_MODE_BROWSER;

  my $description = _description_of($bug->id) or return;
  return unless _extract_mentions($description->{thetext});
  $description->{thetext}      = _without_cloned_text($description->{thetext});
  $bug->{needinfo_description} = $description;
}

sub _description_of {
  my ($bug_id) = @_;
  my $dbh = Bugzilla->dbh;
  return $dbh->selectrow_hashref(
    'SELECT thetext, isprivate FROM longdescs WHERE bug_id = ? '
      . 'ORDER BY comment_id '
      . $dbh->sql_limit(1),
    undef, $bug_id
  );
}

# The header enter_bug.cgi puts above the description it copies when cloning
# a bug (see template/en/default/bug/create/create.html.tmpl). Keep the two in
# sync.
use constant CLONE_HEADER_RE => qr/
  \A \s* \+\+\+ [ ] This [ ] \w+ [ ] was [ ] initially [ ] created [ ] as [ ]
  a [ ] clone [ ] of [ ] \w+ [ ] \#(\d+) [ ] \+\+\+ [^\n]* (?:\n|\z)
/x;

# A clone's description starts with the description of the bug it was cloned
# from, so mentions in it would needinfo everyone mentioned there again. Drop
# the copied lines and keep only what the reporter wrote or edited. If the
# reporter removed the clone header, nothing marks the text as copied and all
# of it counts.
sub _without_cloned_text {
  my ($text)      = @_;
  my ($source_id) = $text =~ CLONE_HEADER_RE or return $text;
  $text =~ s/${\CLONE_HEADER_RE}//;

  # enter_bug.cgi only copies a description the reporter can see, so only
  # remove it under the same conditions.
  my $user = Bugzilla->user;
  return $text unless $user->can_see_bug($source_id);
  my $source = _description_of($source_id) or return $text;
  return $text if $source->{isprivate} && !$user->is_insider;

  return _remove_copied_lines($text, $source->{thetext});
}

# Removes the lines of $text that appear unchanged in $source, each as many
# times as $source has it, so a line the reporter repeats on purpose still
# counts. Blank lines are kept so paragraphs (which end code spans) survive.
sub _remove_copied_lines {
  my ($text, $source) = @_;
  my %copied;
  $copied{$_}++ for grep {/\S/} split /\r?\n/, $source;
  return join "\n",
    grep { !(/\S/ && $copied{$_} && $copied{$_}--) } split /\r?\n/, $text;
}

# process_bug.cgi takes a single bug as `id` and a mass edit as `id_<bug id>`
# params, one per bug.
sub _is_mass_edit {
  return grep {/^id_[1-9]/} Bugzilla->cgi->param;
}

# The needinfo flag type the current user can set on $bug, if any.
sub _needinfo_type {
  my ($bug) = @_;
  my ($type) = grep { $_->name eq 'needinfo' } @{$bug->flag_types};
  return undef
    unless $type
    && $bug->check_can_change_field('flagtypes.name', 0, 1)->{allowed};
  return $type;
}

# What _can_needinfo checks a mention against: how many needinfo flags the
# bug has, and the ids of users with a pending needinfo request. Built from
# the flags in $type->{flags} (none for a bug being filed).
sub _needinfo_state {
  my ($type) = @_;
  my @flags = $type ? @{$type->{flags} || []} : ();
  return {
    count   => scalar @flags,
    pending => {
      map  { $_->requestee_id => 1 }
      grep { $_->status eq '?' && $_->requestee_id } @flags
    },
  };
}

# Whether a mention of $mentioned would request needinfo, given the needinfo
# $type from _needinfo_type and its $state from _needinfo_state. Mirrors the
# checks Bugzilla::Flag makes when the request is saved, so that a request
# which would be rejected is predicted (and handled) as CC-only.
sub _can_needinfo {
  my ($type, $mentioned, $state) = @_;
  return 0 if !$type || $mentioned->needinfo_blocked;
  return 0 unless $type->is_requestable && $type->is_requesteeble;
  return 0 unless Bugzilla->user->can_change_flag($type, 'X', '?');
  return 0 unless $mentioned->can_set_flag($type);

  # A non-multiplicable type allows only one needinfo flag per bug.
  return 0 if !$type->is_multiplicable && $state->{count};
  return 0 if $state->{pending}{$mentioned->id};

  return 1;
}

sub _cc_and_needinfo {
  my ($bug, $mentioned, $type) = @_;
  $bug->add_cc($mentioned);

  return unless _can_needinfo($type, $mentioned, _needinfo_state($type));

  # One call per user so $type->{flags} reflects each flag as it is added.
  $bug->set_flags([],
    [{type_id => $type->id, status => '?', requestee => $mentioned->login}]);
}

# Describes what saving a new comment would do with its @mentions, for the
# live mention warning in the comment editor and the comment preview. $comment
# is a {thetext, isprivate} hash. $target is either {bug => $bug} for a comment
# on an existing bug, or {product => $product, component => $component,
# groups => [group names]} for the initial comment of a bug being filed.
# Returns an array ref of {nick, name, needinfo} hashes, one per user that
# would be CC'd; needinfo is true if they would also get a needinfo request.
sub mention_effects {
  my ($comment, $target) = @_;

  # Saving a new bug doesn't process the mentions in its initial comment yet
  # (bug 2087012), so predict nothing rather than promise notifications that
  # won't be sent. Once it does, return new_bug_mention_effects here.
  my $bug = $target->{bug} or return [];

  my @mentioned = _mentioned_users($bug, [$comment]);
  return [] unless @mentioned;
  return _describe_mentions(_needinfo_type($bug), \@mentioned);
}

# mention_effects for the initial comment of a bug being filed, with $target
# as described there (component and groups are optional). Not used until
# saving a new bug processes its mentions (bug 2087012).
sub new_bug_mention_effects {
  my ($comment, $target) = @_;
  my $product = $target->{product};
  my @mentioned
    = _mentioned_users_for_new_bug($product, $target->{groups}, [$comment]);
  return [] unless @mentioned;

  # A new bug has no flags yet, and the needinfo type is checked against the
  # product (and component) the bug is being filed in.
  my $component = $target->{component};
  my ($type) = @{
    Bugzilla::FlagType::match({
      name         => 'needinfo',
      target_type  => 'bug',
      is_active    => 1,
      product_id   => $product->id,
      component_id => $component ? $component->id : undef,
    })
  };
  return _describe_mentions($type, \@mentioned);
}

# The {nick, name, needinfo} hashes for mention_effects. Saving requests
# needinfo one user at a time, so each predicted request is counted before
# the next user is checked (e.g. only the first user mentioned gets a
# non-multiplicable needinfo). The bug's actual flags are left alone.
sub _describe_mentions {
  my ($type, $mentioned) = @_;
  my $state = _needinfo_state($type);

  return [
    map {
      my $needinfo = _can_needinfo($type, $_, $state);
      if ($needinfo) {
        $state->{count}++;
        $state->{pending}{$_->id} = 1;
      }
      +{nick => $_->nick, name => $_->name, needinfo => $needinfo};
    } @$mentioned
  ];
}

# Lets the comment preview list who saving the comment would CC and needinfo,
# so a stray @word is caught before the comment is submitted. Clients send
# include_mentions (and mention_is_private) along with the bug id only for
# new comments on an existing bug; the description of a new bug has no bug
# to check the mentioned users against, so this hook doesn't preview it.
# The comment editor itself now uses the lighter POST /rest/needinfo/mentions
# endpoint (lib/API/V1/Mentions.pm), which also covers new bugs.
sub webservice_bug_render_comment {
  my ($self, $args) = @_;
  my ($bug, $params) = @$args{qw(bug params)};
  return unless $bug && $params->{include_mentions};

  $args->{result}->{mentions} = mention_effects(
    {thetext => $params->{text}, isprivate => $params->{mention_is_private}},
    {bug     => $bug}
  );
}

sub _check_requestee {
  my ($requestee) = @_;
  my $user
    = ref($requestee)
    ? $requestee
    : Bugzilla::User->new({name => $requestee, cache => 1});
  return unless $user->needinfo_blocked;

  my $blocked_editbugs
    = $user->settings->{block_needinfo}->{value} eq 'editbugs';
  ThrowUserError(
    $blocked_editbugs ? 'needinfo_blocked_editbugs' : 'needinfo_blocked',
    {requestee => $user});
}

sub config_add_panels {
  my ($self, $args) = @_;
  my $modules = $args->{panel_modules};
  $modules->{Needinfo} = "Bugzilla::Extension::Needinfo::Config";
}

sub object_end_of_create {
  my ($self, $args) = @_;
  my $object = $args->{object};
  return
       unless $object->isa('Bugzilla::Flag')
    && $object->type->name eq 'needinfo'
    && $object->requestee;
  _check_requestee($object->requestee);
}

sub object_end_of_update {
  my ($self, $args) = @_;
  my $object = $args->{object};
  return
       unless exists $args->{changes}->{requestee_id}
    && $object->isa('Bugzilla::Flag')
    && $object->type->name eq 'needinfo'
    && $object->requestee;
  _check_requestee($object->requestee);
}

sub object_before_delete {
  my ($self, $args) = @_;
  my $object = $args->{object};
  return
    unless $object->isa('Bugzilla::Flag') && $object->type->name eq 'needinfo';
  my $user = Bugzilla->user;

  # Require canconfirm to clear requests targeted at someone else
  if ( $object->setter_id != $user->id
    && $object->requestee
    && $object->requestee->id != $user->id
    && !$user->in_group('canconfirm'))
  {
    ThrowUserError('needinfo_illegal_change');
  }
}

sub user_preferences {
  my ($self, $args) = @_;
  return unless $args->{current_tab} eq 'account' && $args->{save_changes};

  my $input    = Bugzilla->input_params;
  my $settings = Bugzilla->user->settings;

  my $value = $input->{block_needinfo} // 'off';
  $value = 'on' if $value eq '1';    # stale page still posting the old checkbox
  $settings->{block_needinfo}->validate_value($value);
  $settings->{block_needinfo}->set($value);
  clear_settings_cache(Bugzilla->user->id);
}

__PACKAGE__->NAME;
