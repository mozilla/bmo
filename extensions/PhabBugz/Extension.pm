# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz;

use 5.10.1;
use strict;
use warnings;

use parent qw(Bugzilla::Extension);

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Logging;
use Bugzilla::Mailer qw(MessageToMTA);
use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::User;
use Bugzilla::Extension::PhabBugz::Util qw(request);
use Bugzilla::Util qw(clean_text);

use Try::Tiny;

our $VERSION = '0.01';

sub template_before_process {
  my ($self, $args) = @_;
  my $file = $args->{'file'};
  my $vars = $args->{'vars'};

  return unless Bugzilla->user->id;
  return unless Bugzilla->params->{phabricator_enabled};
  return unless Bugzilla->params->{phabricator_base_uri};

  $vars->{phabricator_available} = 1;

  return unless $file =~ /bug_modal\/(header|edit).html.tmpl$/;

  if (my $bug = exists $vars->{'bugs'} ? $vars->{'bugs'}[0] : $vars->{'bug'}) {
    my $has_revisions = 0;
    my $active_revision_count = 0;
    foreach my $attachment (@{$bug->attachments}) {
      next if $attachment->contenttype ne PHAB_CONTENT_TYPE;
      $active_revision_count++ if !$attachment->isobsolete;
      $has_revisions = 1;
    }
    $vars->{phabricator_revisions} = $has_revisions;
    $vars->{phabricator_active_revision_count} = $active_revision_count;
  }
}

sub config_add_panels {
  my ($self, $args) = @_;
  my $modules = $args->{panel_modules};
  $modules->{PhabBugz} = "Bugzilla::Extension::PhabBugz::Config";
}

sub object_end_of_update {
  my ($self,   $args)    = @_;
  my ($object, $changes) = @$args{qw(object changes)};
  my $params = Bugzilla->params;

  return
       if !$params->{phabricator_enabled}
    || !$object->isa('Bugzilla::User')
    || !$changes
    || !$changes->{disabledtext};

  my $user = $object;

  my $orig_error_mode = Bugzilla->error_mode;
  Bugzilla->error_mode(ERROR_MODE_DIE);

  try {
    my $phab_user
      = Bugzilla::Extension::PhabBugz::User->new_from_query({ids => [$user->id]});
    return if !$phab_user;
    $phab_user->set_user_enabled_status($user->is_enabled);
  }
  catch {
    # We're sending to the maintainer, who may be not a Bugzilla
    # account, but just an email address. So we use the
    # installation's default language for sending the email.
    my $default_settings = Bugzilla::User::Setting::get_defaults();
    my $template
      = Bugzilla->template_inner($default_settings->{lang}->{default_value});
    my $vars = {user => $user, error => $_};
    my $message;
    $template->process('email/phab_enabled_status.txt.tmpl', $vars, \$message)
      || ThrowTemplateError($template->error);
    MessageToMTA($message);

    WARN('ERROR: Error updating Phabricator user status for Bugzilla user '
        . $user->login);
  };

  Bugzilla->error_mode($orig_error_mode);
}

sub object_start_of_update {
  my ($self,       $args)       = @_;
  my ($new_object, $old_object) = @$args{qw( object old_object )};

  return unless $new_object->isa('Bugzilla::Attachment');

  # Only allow phab-bot to set content type to text/x-phabricator-request
  my $old_content_type = $old_object->contenttype;
  my $new_content_type = $new_object->contenttype;

  if ($old_content_type ne $new_content_type
    && $new_content_type eq PHAB_CONTENT_TYPE
    && !Bugzilla->request_cache->{allow_phab_revision_attachment})
  {
    Bugzilla->audit(
      sprintf
        'WARN: User %s attempted to update an attachment to phabricator content type %s',
      Bugzilla->user->login, $new_content_type
    );
    $new_object->set_content_type($old_content_type);
    $new_object->set_is_patch($old_object->ispatch);
  }
}

sub object_before_create {
  my ($self,  $args)   = @_;
  my ($class, $params) = @$args{qw(class params)};

  return if $class ne 'Bugzilla::Attachment';

  # Only allow phab-bot to set content type to text/x-phabricator-request
  # Normalize before comparing — storage applies clean_text() (control-char
  # substitution + trim) after this hook runs, so variants like
  # "text/x-phabricator-request " or "text/x-phabricator-request\x00" would
  # bypass an un-normalized eq check.
  my $content_type = clean_text($params->{mimetype} // '');
  $params->{mimetype} = $content_type if $content_type;
  if ($content_type && $content_type eq PHAB_CONTENT_TYPE
    && !Bugzilla->request_cache->{allow_phab_revision_attachment})
  {
    Bugzilla->audit(
      sprintf
        'WARN: User %s attempted to create an attachment with phabricator content type %s',
      Bugzilla->user->login, $content_type
    );
    $params->{mimetype} = undef;
  }
}

#
# installation/config hooks
#

sub db_schema_abstract_schema {
  my ($self, $args) = @_;
  $args->{'schema'}->{'phabbugz'} = {
    FIELDS => [
      id    => {TYPE => 'INTSERIAL',    NOTNULL => 1, PRIMARYKEY => 1,},
      name  => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
      value => {TYPE => 'MEDIUMTEXT',   NOTNULL => 1}
    ],
    INDEXES => [phabbugz_idx => {FIELDS => ['name'], TYPE => 'UNIQUE',},],
  };
  $args->{'schema'}->{'phab_reviewer_rotation'} = {
    FIELDS => [
      id            => {TYPE => 'INTSERIAL',    NOTNULL => 1, PRIMARYKEY => 1,},
      project_phid  => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
      user_phid     => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
    ]
  };
  $args->{'schema'}->{'phab_uplift_form_state'} = {
    FIELDS => [
      id               => {TYPE => 'INTSERIAL',    NOTNULL => 1, PRIMARYKEY => 1,},
      revision_phid    => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
      uplift_form_hash => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
    ]
  };
}

sub install_filesystem {
  my ($self, $args) = @_;
  my $files = $args->{'files'};

  my $extensionsdir = bz_locations()->{'extensionsdir'};
  my $scriptname    = $extensionsdir . "/PhabBugz/bin/phabbugz_feed.pl";

  $files->{$scriptname} = {perms => Bugzilla::Install::Filesystem::WS_EXECUTE};
}

sub merge_users_before {
  my ($self, $args) = @_;
  my $old_id = $args->{old_id};
  my $force  = $args->{force};

  return if $force;

  my $result = request('bugzilla.account.search', {ids => [$old_id]});

  foreach my $user (@{$result->{result}}) {
    next if !$user->{phid};
    ThrowUserError('phabricator_merge_user_abort',
      {user => Bugzilla::User->new({id => $old_id, cache => 1})});
  }
}

__PACKAGE__->NAME;
