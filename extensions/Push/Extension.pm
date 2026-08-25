# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Push;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Extension);

use Bugzilla::Constants;
use Bugzilla::Comment;
use Bugzilla::Error;
use Bugzilla::Extension::Push::Admin;
use Bugzilla::Extension::Push::Connectors;
use Bugzilla::Extension::Push::Logger;
use Bugzilla::Extension::Push::Message;
use Bugzilla::Extension::Push::Push;
use Bugzilla::Extension::Push::Serialize;
use Bugzilla::Extension::Push::Util;
use Bugzilla::Install::Filesystem;

use Encode;
use Scalar::Util 'blessed';
use Storable 'dclone';

our $VERSION = '1';

$Carp::CarpInternal{'CGI::Carp'} = 1;

#
# monkey patch for convenience
#

BEGIN {
  *Bugzilla::push_ext = \&_get_instance;
}

sub _get_instance {
  my $cache = Bugzilla->request_cache;
  if (!$cache->{'push.instance'}) {
    my $instance = Bugzilla::Extension::Push::Push->new();
    $cache->{'push.instance'} = $instance;
    $instance->logger(Bugzilla::Extension::Push::Logger->new());
    $instance->connectors(Bugzilla::Extension::Push::Connectors->new());
  }
  return $cache->{'push.instance'};
}

#
# enabled
#

sub _enabled {
  my ($self) = @_;
  my $cache = Bugzilla->request_cache->{+__PACKAGE__} //= {};

  if (!exists $cache->{'enabled'}) {
    my $push = Bugzilla->push_ext;
    $cache->{'enabled'} = $push->config->{enabled} eq 'Enabled';
    if ($cache->{'enabled'}) {

      # if no connectors are enabled, no need to push anything
      $cache->{'enabled'} = 0;
      foreach my $connector (Bugzilla->push_ext->connectors->list) {
        if ($connector->enabled) {
          $cache->{'enabled'} = 1;
          last;
        }
      }
    }
  }
  return $cache->{'enabled'};
}

#
# deal with creation and updated events
#

sub _object_created {
  my ($self, $args) = @_;

  my $object = _get_object_from_args($args);
  return unless $object;
  return unless _should_push($object);

  $self->_push_object('create', $object, change_set_id(),
    {timestamp => $args->{'timestamp'}});
}

sub _object_modified {
  my ($self, $args) = @_;

  my $object = _get_object_from_args($args);
  return unless $object;
  return unless _should_push($object);

  my $changes = $args->{'changes'} || {};
  return unless scalar keys %$changes;

  my $change_set = change_set_id();

  # detect when a bug changes from public to private (or back), so connectors
  # can remove now-private bugs if required.
  if ($object->isa('Bugzilla::Bug')) {

    # we can't use user->can_see_bug(old_bug) as that works on IDs, and the
    # bug has already been updated, so for now assume that a bug without
    # groups is public.
    my $old_bug    = $args->{'old_bug'};
    my $is_public  = is_public($object);
    my $was_public = $old_bug ? !@{$old_bug->groups_in} : $is_public;

    if (!$is_public && $was_public) {

      # bug is changing from public to private
      # push a fake update with the just is_private change
      my $private_changes = {
        timestamp => $args->{'timestamp'},
        changes   => [{field => 'is_private', removed => '0', added => '1',},],
      };

      # note we're sending the old bug object so we don't leak any
      # security sensitive information.
      $self->_push_object('modify', $old_bug, $change_set, $private_changes);
    }
    elsif ($is_public && !$was_public) {

      # bug is changing from private to public
      # push a fake update with the just is_private change
      my $private_changes = {
        timestamp => $args->{'timestamp'},
        changes   => [{field => 'is_private', removed => '1', added => '0',},],
      };

      # it's ok to send the new bug state here
      $self->_push_object('modify', $object, $change_set, $private_changes);
    }
  }

  # make flagtypes changes easier to process
  if (exists $changes->{'flagtypes.name'}) {
    _split_flagtypes($changes);
  }

  # TODO split group changes?

  # restructure the changes hash
  my $changes_data = {timestamp => $args->{'timestamp'}, changes => [],};
  foreach my $field_name (sort keys %$changes) {
    my $new_field_name = $field_name;
    $new_field_name =~ s/isprivate/is_private/;

    push @{$changes_data->{'changes'}},
      {
      field   => $new_field_name,
      removed => $changes->{$field_name}[0],
      added   => $changes->{$field_name}[1],
      };
  }

  $self->_push_object('modify', $object, $change_set, $changes_data);

  # Dependency/regression relationship edits on one bug also affect the
  # corresponding field on related bugs; emit synthetic modify events so
  # webhook consumers receive both sides of the relationship change.
  $self->_emit_counterpart_bug_modify_events(
    $object,
    $changes,
    $args->{'timestamp'},
    $change_set,
  );
}

sub _emit_counterpart_bug_modify_events {
  my ($self, $source_bug, $changes, $timestamp, $change_set) = @_;

  return unless $source_bug && $source_bug->isa('Bugzilla::Bug');
  return unless $changes && scalar keys %$changes;

  my $counterpart_changes = _counterpart_bug_changes($source_bug, $changes);
  my @related_bug_ids = sort { $a <=> $b } keys %$counterpart_changes;
  return unless @related_bug_ids;

  my $related_bugs = Bugzilla::Bug->new_from_list(\@related_bug_ids);
  my %related_bug_map = map { $_->id => $_ } grep { !$_->{error} } @$related_bugs;

  foreach my $related_bug_id (@related_bug_ids) {
    my $related_bug = $related_bug_map{$related_bug_id};
    next if !$related_bug;

    # Do not emit counterpart payloads for private target bugs because
    # connectors may not uniformly apply per-consumer visibility checks.
    next unless is_public($related_bug);

    my $related_changes_data = {
      timestamp => $timestamp,
      changes   => $counterpart_changes->{$related_bug_id},
      indirect_change => {
        type          => 'related',
        source_bug_id => $source_bug->id,
      },
    };
    $self->_push_object('modify', $related_bug, $change_set, $related_changes_data);
  }
}

sub _counterpart_bug_changes {
  my ($source_bug, $changes) = @_;

  my %field_map = (
    blocked      => 'dependson',
    dependson    => 'blocked',
    regresses    => 'regressed_by',
    regressed_by => 'regresses',
  );

  my %result;
  foreach my $source_field (sort keys %field_map) {
    next unless exists $changes->{$source_field};

    my $counterpart_field = $field_map{$source_field};
    my ($old_value, $new_value) = @{$changes->{$source_field}};
    my $old_ids = _parse_related_bug_ids($old_value);
    my $new_ids = _parse_related_bug_ids($new_value);

    my %all_ids = map { $_ => 1 } (keys %$old_ids, keys %$new_ids);
    foreach my $related_bug_id (sort { $a <=> $b } keys %all_ids) {
      my $in_old = exists $old_ids->{$related_bug_id};
      my $in_new = exists $new_ids->{$related_bug_id};
      next if $in_old == $in_new;

      push @{$result{$related_bug_id}}, {
        field   => $counterpart_field,
        removed => $in_old ? $source_bug->id : '',
        added   => $in_new ? $source_bug->id : '',
      };
    }
  }

  return \%result;
}

sub _parse_related_bug_ids {
  my ($raw_value) = @_;

  my $value = '';
  if (ref $raw_value eq 'ARRAY') {
    $value = join(',', @$raw_value);
  }
  elsif (defined $raw_value) {
    $value = $raw_value;
  }

  my %ids;
  foreach my $id (split(/[\s,]+/, $value)) {
    next unless $id =~ /^\d+$/;
    $ids{$id} = 1;
  }

  return \%ids;
}

sub _get_object_from_args {
  my ($args) = @_;
  return get_first_value($args, qw(object bug flag group));
}

sub _should_push {
  my ($object_or_class) = @_;
  my $class = blessed($object_or_class) || $object_or_class;
  return
    grep { $_ eq $class }
    qw(Bugzilla::Bug Bugzilla::Attachment Bugzilla::Comment);
}

# changes to bug flags are presented in a single field 'flagtypes.name' split
# into individual fields
sub _split_flagtypes {
  my ($changes) = @_;

  my @removed = _split_flagtype($changes->{'flagtypes.name'}->[0]);
  my @added   = _split_flagtype($changes->{'flagtypes.name'}->[1]);
  delete $changes->{'flagtypes.name'};

  foreach my $ra (@removed, @added) {
    $changes->{$ra->[0]} = ['', ''];
  }
  foreach my $ra (@removed) {
    my ($name, $value) = @$ra;
    $changes->{$name}->[0] = $value;
  }
  foreach my $ra (@added) {
    my ($name, $value) = @$ra;
    $changes->{$name}->[1] = $value;
  }
}

sub _split_flagtype {
  my ($value) = @_;
  my @result;
  foreach my $change (split(/, /, $value)) {
    my $requestee = '';
    if ($change =~ s/\(([^\)]+)\)$//) {
      $requestee = $1;
    }
    my ($name, $value) = $change =~ /^(.+)(.)$/;
    $value .= " ($requestee)" if $requestee;
    push @result, ["flag.$name", $value];
  }
  return @result;
}

# changes to attachment flags come in via flag_end_of_update which has a
# completely different structure for reporting changes than
# object_end_of_update.  this morphs flag to object updates.
sub _morph_flag_updates {
  my ($args) = @_;

  my @removed = _morph_flag_update($args->{'old_flags'});
  my @added   = _morph_flag_update($args->{'new_flags'});

  my $changes = {};
  foreach my $ra (@removed, @added) {
    $changes->{$ra->[0]} = ['', ''];
  }
  foreach my $ra (@removed) {
    my ($name, $value) = @$ra;
    $changes->{$name}->[0] = $value;
  }
  foreach my $ra (@added) {
    my ($name, $value) = @$ra;
    $changes->{$name}->[1] = $value;
  }

  foreach my $flag (keys %$changes) {
    if ($changes->{$flag}->[0] eq $changes->{$flag}->[1]) {
      delete $changes->{$flag};
    }
  }

  $args->{'changes'} = $changes;
}

sub _morph_flag_update {
  my ($values) = @_;
  my @result;
  foreach my $orig_change (@$values) {
    my $change = $orig_change;    # work on a copy
    $change =~ s/^[^:]+://;
    my $requestee = '';
    if ($change =~ s/\(([^\)]+)\)$//) {
      $requestee = $1;
    }
    my ($name, $value) = $change =~ /^(.+)(.)$/;
    $value .= " ($requestee)" if $requestee;
    push @result, ["flag.$name", $value];
  }
  return @result;
}

#
# serialize and insert into the table
#

sub _push_object {
  my ($self, $message_type, $object, $change_set, $changes) = @_;
  my $rh;

  # serialize the object
  my ($rh_object, $name)
    = Bugzilla::Extension::Push::Serialize->instance->object_to_hash($object);

  if (!$rh_object) {
    warn "empty hash from serializer ($message_type $object)\n";
    return;
  }
  $rh->{$name} = $rh_object;

  # add in the events hash
  my $rh_event
    = Bugzilla::Extension::Push::Serialize->instance->changes_to_event($changes);
  return unless $rh_event;
  $rh_event->{'action'}      = $message_type;
  $rh_event->{'target'}      = $name;
  $rh_event->{'change_set'}  = $change_set;
  if (exists $changes->{'indirect_change'}) {
    $rh_event->{'indirect_change'} = $changes->{'indirect_change'};
  }
  $rh_event->{'routing_key'} = "$name.$message_type";
  if (exists $rh_event->{'changes'}) {
    $rh_event->{'routing_key'}
      .= ':' . join(',', map { $_->{'field'} } @{$rh_event->{'changes'}});
  }
  $rh->{'event'} = $rh_event;

  # create message object
  my $message = Bugzilla::Extension::Push::Message->new_transient({
    payload     => to_json($rh),
    change_set  => $change_set,
    routing_key => $rh_event->{'routing_key'},
  });

  # don't hit the database unless there are interested connectors
  my $should_push = 0;
  foreach my $connector (Bugzilla->push_ext->connectors->list) {
    next unless $connector->enabled;
    next unless $connector->should_send($message);
    $should_push = 1;
    last;
  }
  return unless $should_push;

  # insert into push table
  $message->create_from_transient();
}

#
# update/create hooks
#

sub bug_before_create {
  my ($self, $args) = @_;
  return unless $self->_enabled;

  my $params = $args->{params} || return;
  my $stash  = $args->{stash}  || return;

  my %relation_values;
  foreach my $field (qw(blocked dependson regresses regressed_by)) {
    my $value = $params->{$field};
    next unless ref $value eq 'ARRAY' && @$value;
    $relation_values{$field} = [@$value];
  }

  return unless keys %relation_values;
  $stash->{push_creation_relation_values} = \%relation_values;
}

sub object_end_of_create {
  my ($self, $args) = @_;
  return unless $self->_enabled;

  # it's better to process objects from a non-generic end_of_create where
  # possible; don't process them here to avoid duplicate messages
  my $object = _get_object_from_args($args);
  return
       if !$object
    || $object->isa('Bugzilla::Bug')
    || blessed($object) =~ /^Bugzilla::Extension/;

  $self->_object_created($args);
}

sub object_end_of_update {
  my ($self, $args) = @_;

  # User objects are updated with every page load (to touch the session
  # token).  Because we ignore user objects, there's no need to create an
  # instance of Push to check if we're enabled.
  my $object = _get_object_from_args($args);
  return if !$object || $object->isa('Bugzilla::User');

  return unless $self->_enabled;

  # it's better to process objects from a non-generic end_of_update where
  # possible; don't process them here to avoid duplicate messages
  return
       if $object->isa('Bugzilla::Bug')
    || $object->isa('Bugzilla::Flag')
    || blessed($object) =~ /^Bugzilla::Extension/;

  $self->_object_modified($args);
}

# process bugs once they are fully formed
# object_end_of_update is triggered while a bug is being created
sub bug_end_of_create {
  my ($self, $args) = @_;
  return unless $self->_enabled;
  $self->_object_created($args);

  my $bug = $args->{bug};
  return unless $bug && $bug->isa('Bugzilla::Bug');

  my $stash = $args->{stash};
  return unless ref $stash eq 'HASH';
  return unless exists $stash->{push_creation_relation_values};

  my $creation_relation_values = $stash->{push_creation_relation_values};

  my %creation_relation_changes;
  foreach my $field (qw(blocked dependson regresses regressed_by)) {
    my $related_ids = $creation_relation_values->{$field} || [];
    next unless @$related_ids;
    $creation_relation_changes{$field} = ['', join(', ', @$related_ids)];
  }

  $self->_emit_counterpart_bug_modify_events(
    $bug,
    \%creation_relation_changes,
    $args->{timestamp},
    change_set_id(),
  );
}

sub bug_end_of_update {
  my ($self, $args) = @_;
  return unless $self->_enabled;
  $self->_object_modified($args);
}

sub flag_end_of_update {
  my ($self, $args) = @_;
  return unless $self->_enabled;
  _morph_flag_updates($args);
  $self->_object_modified($args);
  delete $args->{changes};
}

# comments in Bugzilla 4.0 doesn't aren't included in the bug_end_of_* hooks,
# this code uses custom hooks to trigger
sub bug_comment_create {
  my ($self, $args) = @_;
  return unless $self->_enabled;

  return unless _should_push('Bugzilla::Comment');
  my $bug       = $args->{'bug'}       or return;
  my $timestamp = $args->{'timestamp'} or return;

  my $comments
    = Bugzilla::Comment->match({bug_id => $bug->id, bug_when => $timestamp});

  foreach my $comment (@$comments) {
    if ($comment->body ne '') {
      $self->_push_object('create', $comment, change_set_id(),
        {timestamp => $timestamp});
    }
  }
}

sub bug_comment_update {
  my ($self, $args) = @_;
  return unless $self->_enabled;

  return unless _should_push('Bugzilla::Comment');
  my $bug       = $args->{'bug'}       or return;
  my $timestamp = $args->{'timestamp'} or return;

  my $comment_id = $args->{'comment_id'};
  if ($comment_id) {

    # XXX this should set changes.  only is_private changes will trigger this event
    my $comment = Bugzilla::Comment->new($comment_id);
    $self->_push_object('update', $comment, change_set_id(),
      {timestamp => $timestamp});

  }
  else {
    # when a bug is created, an update is also triggered; we don't want to sent
    # update messages for the initial comment, or for empty comments
    my $comments
      = Bugzilla::Comment->match({bug_id => $bug->id, bug_when => $timestamp});
    foreach my $comment (@$comments) {
      if ($comment->body ne '' && $comment->count) {
        $self->_push_object('create', $comment, change_set_id(),
          {timestamp => $timestamp});
      }
    }
  }
}

#
# admin hooks
#

sub page_before_template {
  my ($self, $args) = @_;
  my $page = $args->{'page_id'};
  my $vars = $args->{'vars'};

  if ($page eq 'push_config.html') {
    Bugzilla->user->in_group('admin')
      || ThrowUserError('auth_failure',
      {group => 'admin', action => 'access', object => 'administrative_pages'});
    admin_config($vars);

  }
  elsif ($page eq 'push_queues.html' || $page eq 'push_queues_view.html') {
    Bugzilla->user->in_group('admin')
      || ThrowUserError('auth_failure',
      {group => 'admin', action => 'access', object => 'administrative_pages'});
    admin_queues($vars, $page);

  }
  elsif ($page eq 'push_log.html') {
    Bugzilla->user->in_group('admin')
      || ThrowUserError('auth_failure',
      {group => 'admin', action => 'access', object => 'administrative_pages'});
    admin_log($vars);
  }
  elsif ($page eq 'webhooks_config.html') {
    if (Bugzilla->params->{webhooks_enabled}){
      Bugzilla->user->in_group('admin')
        || ThrowUserError('auth_failure',
        {group => 'admin', action => 'access', object => 'administrative_pages'});
      admin_webhooks($vars);
    }else{
      ThrowUserError('webhooks_disabled');
    }
  }
}

#
# installation/config hooks
#

sub db_schema_abstract_schema {
  my ($self, $args) = @_;
  $args->{'schema'}->{'push'} = {
    FIELDS => [
      id          => {TYPE => 'MEDIUMSERIAL', NOTNULL => 1, PRIMARYKEY => 1,},
      push_ts     => {TYPE => 'DATETIME',     NOTNULL => 1,},
      payload     => {TYPE => 'LONGTEXT',     NOTNULL => 1,},
      change_set  => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      routing_key => {TYPE => 'VARCHAR(64)',  NOTNULL => 1,},
    ],
  };
  $args->{'schema'}->{'push_backlog'} = {
    FIELDS => [
      id          => {TYPE => 'MEDIUMSERIAL', NOTNULL => 1, PRIMARYKEY => 1,},
      message_id  => {TYPE => 'INT3',         NOTNULL => 1,},
      push_ts     => {TYPE => 'DATETIME',     NOTNULL => 1,},
      payload     => {TYPE => 'LONGTEXT',     NOTNULL => 1,},
      change_set  => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      routing_key => {TYPE => 'VARCHAR(64)',  NOTNULL => 1,},
      connector   => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      attempt_ts  => {TYPE => 'DATETIME',},
      attempts    => {TYPE => 'INT2',         NOTNULL => 1,},
      last_error  => {TYPE => 'MEDIUMTEXT',},
    ],
    INDEXES => [
      push_backlog_idx => {FIELDS => ['message_id', 'connector'], TYPE => 'UNIQUE',},
    ],
  };
  $args->{'schema'}->{'push_backoff'} = {
    FIELDS => [
      id              => {TYPE => 'MEDIUMSERIAL', NOTNULL => 1, PRIMARYKEY => 1,},
      connector       => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      next_attempt_ts => {TYPE => 'DATETIME',},
      attempts        => {TYPE => 'INT2',         NOTNULL => 1,},
    ],
    INDEXES => [push_backoff_idx => {FIELDS => ['connector'], TYPE => 'UNIQUE',},],
  };
  $args->{'schema'}->{'push_options'} = {
    FIELDS => [
      id           => {TYPE => 'MEDIUMSERIAL', NOTNULL => 1, PRIMARYKEY => 1,},
      connector    => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      option_name  => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      option_value => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
    ],
    INDEXES => [
      push_options_idx => {FIELDS => ['connector', 'option_name'], TYPE => 'UNIQUE',},
    ],
  };
  $args->{'schema'}->{'push_log'} = {
    FIELDS => [
      id           => {TYPE => 'MEDIUMSERIAL', NOTNULL => 1, PRIMARYKEY => 1,},
      message_id   => {TYPE => 'INT3',         NOTNULL => 1,},
      change_set   => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      routing_key  => {TYPE => 'VARCHAR(64)',  NOTNULL => 1,},
      connector    => {TYPE => 'VARCHAR(32)',  NOTNULL => 1,},
      push_ts      => {TYPE => 'DATETIME',     NOTNULL => 1,},
      processed_ts => {TYPE => 'DATETIME',     NOTNULL => 1,},
      result       => {TYPE => 'INT1',         NOTNULL => 1,},
      data         => {TYPE => 'MEDIUMTEXT',},
    ],
  };
}

sub install_filesystem {
  my ($self, $args) = @_;
  my $files = $args->{'files'};

  my $extensionsdir = bz_locations()->{'extensionsdir'};
  my $scriptname    = $extensionsdir . "/Push/bin/bugzilla-pushd.pl";

  $files->{$scriptname} = {perms => Bugzilla::Install::Filesystem::WS_EXECUTE};
}

sub db_sanitize {
  my $dbh = Bugzilla->dbh;
  print "Deleting push extension logs and messages...\n";
  $dbh->do("DELETE FROM push");
  $dbh->do("DELETE FROM push_backlog");
  $dbh->do("DELETE FROM push_backoff");
  $dbh->do("DELETE FROM push_log");
  $dbh->do("DELETE FROM push_options");
}

__PACKAGE__->NAME;
