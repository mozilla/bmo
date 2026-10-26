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
# _process_mentions. Shared by saving and the comment preview so the preview
# can't disagree with what actually happens. $old_bug is only passed when
# saving, to account for groups added in the same update.
sub _mentioned_users {
  my ($bug, $comments, $old_bug) = @_;
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
  return () unless $user->in_group('editbugs', $bug->product_id);

  # can_see_bug reads the groups stored in the database, which don't yet
  # include groups added by this update, so check those separately.
  my @added_groups;
  if ($old_bug) {
    my %old_groups = map { $_->id => 1 } @{$old_bug->groups_in};
    @added_groups
      = map { $_->name } grep { !$old_groups{$_->id} } @{$bug->groups_in};
  }

  return grep {
    my $mentioned = $_;
         $mentioned->id != $user->id
      && ($public{lc $mentioned->nick} || $mentioned->is_insider)
      && $mentioned->can_see_bug($bug->id)
      && all { $mentioned->in_group($_) } @added_groups
  } _users_for_mentions(@nicks);
}

# GitHub-style mentions: each @nickname in a new comment is CC'd and gets a
# needinfo request. Mentions never block the comment from being saved; anyone
# who can't be needinfo'd (blocked, already asked, no permission, or the
# needinfo type isn't multiplicable and a flag exists) is only CC'd.
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
  return unless Bugzilla->usage_mode == USAGE_MODE_BROWSER;
  return if _is_mass_edit();

  my @mentioned
    = _mentioned_users($bug, $bug->{added_comments} || [], $old_bug);
  return unless @mentioned;

  my ($type) = grep { $_->name eq 'needinfo' } @{$bug->flag_types};
  undef $type
    unless $type && $bug->check_can_change_field('flagtypes.name', 0, 1)->{allowed};

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

# process_bug.cgi takes a single bug as `id` and a mass edit as `id_<bug id>`
# params, one per bug.
sub _is_mass_edit {
  return grep {/^id_[1-9]/} Bugzilla->cgi->param;
}

sub _cc_and_needinfo {
  my ($bug, $mentioned, $type) = @_;
  $bug->add_cc($mentioned);

  return if !$type || $mentioned->needinfo_blocked;

  # A non-multiplicable type allows only one needinfo flag per bug.
  return if !$type->is_multiplicable && @{$type->{flags}};
  return if grep {
    $_->status eq '?' && ($_->requestee_id // 0) == $mentioned->id
  } @{$type->{flags}};

  # One call per user so $type->{flags} reflects each flag as it is added.
  $bug->set_flags([],
    [{type_id => $type->id, status => '?', requestee => $mentioned->login}]);
}

# Lets the comment preview list who saving the comment would CC and needinfo,
# so a stray @word is caught before the comment is submitted. The comment
# editor sends include_mentions (and mention_is_private) along with the bug id
# only for new comments on an existing bug, the only case _process_mentions
# handles.
sub webservice_bug_render_comment {
  my ($self, $args) = @_;
  my ($bug, $params) = @$args{qw(bug params)};
  return unless $bug && $params->{include_mentions};

  my @mentioned = _mentioned_users($bug,
    [{thetext => $params->{text}, isprivate => $params->{mention_is_private}}]);

  $args->{result}->{mentions}
    = [map { +{nick => $_->nick, name => $_->name} } @mentioned];
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
