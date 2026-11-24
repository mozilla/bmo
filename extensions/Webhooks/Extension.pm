# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Webhooks;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Extension);

use Bugzilla::Component;
use Bugzilla::Product;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::User;
use Bugzilla::Logging;
use Bugzilla::Mailer qw(MessageToMTA);
use Bugzilla::Extension::Webhooks::Webhook;
use Bugzilla::Extension::Push::Util;
use Bugzilla::Token qw(check_hash_token);
use Bugzilla::Util;
use Try::Tiny;

#
# installation
#

sub db_schema_abstract_schema {
  my ($self, $args) = @_;
  my $dbh = Bugzilla->dbh;
  $args->{'schema'}->{'webhooks'} = {
    FIELDS => [
      id      => {TYPE => 'INTSERIAL', NOTNULL => 1, PRIMARYKEY => 1,},
      user_id => {
        TYPE       => 'INT3',
        NOTNULL    => 1,
        REFERENCES => {TABLE => 'profiles', COLUMN => 'userid', DELETE => 'CASCADE',}
      },
      name       => {TYPE => 'VARCHAR(64)',  NOTNULL => 1,},
      url        => {TYPE => 'VARCHAR(255)', NOTNULL => 1,},
      event      => {TYPE => 'VARCHAR(64)',  NOTNULL => 1,},
      product_id => {
        TYPE       => 'INT2',
        NOTNULL    => 0,
        REFERENCES => {TABLE => 'products', COLUMN => 'id', DELETE => 'CASCADE',}
      },
      component_id => {
        TYPE       => 'INT2',
        NOTNULL    => 0,
        REFERENCES => {TABLE => 'components', COLUMN => 'id', DELETE => 'CASCADE',}
      },
      api_key_header => {TYPE => 'VARCHAR(64)'},
      api_key_value  => {TYPE => 'VARCHAR(64)'},
    ],
    INDEXES => [
      webhooks_userid_name_idx => {FIELDS => ['user_id', 'name'], TYPE => 'UNIQUE',},
    ],
  };
}

sub install_update_db {
  my $dbh = Bugzilla->dbh;
  $dbh->bz_add_column('webhooks', 'api_key_header', {TYPE => 'VARCHAR(64)'});
  $dbh->bz_add_column('webhooks', 'api_key_value',  {TYPE => 'VARCHAR(64)'});
  $dbh->bz_alter_column(
    'webhooks',
    'product_id',
    {
      TYPE       => 'INT2',
      NOTNULL    => 0,
      REFERENCES => {TABLE => 'products', COLUMN => 'id', DELETE => 'CASCADE',}
    }
  );
  $dbh->bz_alter_column('webhooks', 'url',
    {TYPE => 'varchar(255)', NOTNULL => 1});
}

sub db_sanitize {
  my $dbh = Bugzilla->dbh;
  print "Deleting webhooks...\n";
  $dbh->do("DELETE FROM webhooks");
}

#
# preferences
#

sub user_preferences {
  my ($self, $args) = @_;

  return
    unless Bugzilla->params->{webhooks_enabled}
    && Bugzilla->user->in_group(Bugzilla->params->{"webhooks_group"});
  return unless $args->{'current_tab'} eq 'webhooks';

  my $input = Bugzilla->input_params;
  my $user  = Bugzilla->user;
  my $push  = Bugzilla->push_ext;
  my $vars  = $args->{vars};

  if ($args->{'save_changes'}) {

    if ($input->{'add_webhook'}) {

      # add webhook

      my $params = {user_id => $user->id,};

      $input->{name} = trim($input->{name});
      $input->{url}  = trim($input->{url});

      if ($input->{name} eq '') {
        ThrowUserError('webhooks_define_name');
      }
      else {
        $params->{name} = $input->{name};
      }

      if ($input->{url} eq '') {
        ThrowUserError('webhooks_define_url');
      }
      else {
        $params->{url} = $input->{url};
      }

      my @events = grep {$_}
        ref($input->{event}) eq 'ARRAY' ? @{$input->{event}} : $input->{event};

      # the needinfo event can't be offered without a needinfo flag type
      @events = grep { $_ ne 'needinfo' } @events
        unless Bugzilla::Extension::Webhooks::Webhook->needinfo_available;

      if (@events) {
        $params->{event} = join(',', @events);
      }
      else {
        ThrowUserError('webhooks_select_event');
      }

      my $product_name = $input->{product};

      # Selecting product equal to 'any' requires special group membership
      if (!$product_name || $product_name eq 'Any') {
        if (!$user->in_group(Bugzilla->params->{webhooks_any_product_group})) {
          ThrowUserError('webhooks_any_product_not_allowed');
        }
        $params->{product_id}   = undef;
        $params->{component_id} = undef;
      }
      else {
        my $product = Bugzilla::Product->check({name => $product_name, cache => 1});
        $params->{product_id} = $product->id;

        my $component_name = $input->{component};
        if ($component_name && $component_name ne 'Any') {
          my $component
            = Bugzilla::Component->check({
            name => $component_name, product => $product, cache => 1
            });
          $params->{component_id} = $component->id;
        }
      }

      if ($input->{api_key_header}) {
        $params->{api_key_header} = $input->{api_key_header};
      }

      if ($input->{api_key_value}) {
        $params->{api_key_value} = $input->{api_key_value};
      }

      my $new_webhook = Bugzilla::Extension::Webhooks::Webhook->create($params);

      create_push_connector($new_webhook->{id});

    }
    else {

      # remove webhook(s)

      my $ids  = ref($input->{remove}) ? $input->{remove} : [$input->{remove}];
      my $dbh  = Bugzilla->dbh;
      my $push = Bugzilla->push_ext;

      my $webhooks = Bugzilla::Extension::Webhooks::Webhook->match(
        {id => $ids, user_id => $user->id});
      $dbh->bz_start_transaction;
      foreach my $webhook (@$webhooks) {
        delete_backlog_queue($webhook->id);
        $webhook->remove_from_db();
      }
      $dbh->bz_commit_transaction();

      # save change(s)

      $webhooks
        = Bugzilla::Extension::Webhooks::Webhook->match({user_id => $user->id});
      $dbh->bz_start_transaction;
      foreach my $webhook (@$webhooks) {
        my $connector    = $push->connectors->by_name('Webhook_' . $webhook->id);
        my $config       = $connector->config;
        my $was_disabled = $connector->enabled ? 0 : 1;
        my $status       = trim($input->{$connector->name . ".enabled"});
        if ($status eq 'Enabled' || $status eq 'Disabled') {
          # This might have been disabled due to large number of errors.
          # In that case we want to reset the attempts to 0 if we are
          # re-enabling the webhook
          if ($was_disabled && $status eq 'Enabled') {
            $connector->backlog->reset_backoff;
            if (my $message = $connector->backlog->oldest) {
              $message->{attempts} = 0;
              $message->update;
            }
          }
          $config->{enabled} = $status;
          $config->update();
        }
        else {
          ThrowUserError('webhooks_invalid_option');
        }
      }
      $dbh->bz_commit_transaction();
    }

    $push->set_config_last_modified();
  }

  $vars->{webhooks} = [
    sort {
           $a->product_name cmp $b->product_name
        || $a->component_name cmp $b->component_name
    } @{Bugzilla::Extension::Webhooks::Webhook->match({user_id => $user->id,})}
  ];
  $vars->{push}           = $push;
  $vars->{connectors}     = $push->connectors;
  $vars->{webhooks_saved} = 1;
  $vars->{needinfo_available}
    = Bugzilla::Extension::Webhooks::Webhook->needinfo_available;

  ${$args->{handled}} = 1;
}

#
# admin
#

sub config_add_panels {
  my ($self, $args) = @_;
  my $modules = $args->{panel_modules};
  $modules->{Webhooks} = "Bugzilla::Extension::Webhooks::Config";
}

#
# templates
#

sub template_before_process {
  my ($self, $args) = @_;
  return
    if Bugzilla->params->{webhooks_enabled}
    && Bugzilla->user->in_group(Bugzilla->params->{"webhooks_group"});
  my ($vars, $file) = @$args{qw(vars file)};
  return unless $file eq 'account/prefs/tabs.html.tmpl';
  @{$vars->{tabs}} = grep { $_->{name} ne 'webhooks' } @{$vars->{tabs}};
}

#
# push connector
#

sub create_push_connector {
  my ($webhook_id) = @_;
  my $webhook_name = 'Webhoook_' . $webhook_id;
  my $package      = "Bugzilla::Extension::Push::Connector::Webhook";
  try {
    my $connector = $package->new($webhook_id);
    $connector->load_config();
    $connector->save();
  }
  catch {
    ERROR("Connector '$webhook_name' failed to load: " . clean_error($_));
  };
}

sub delete_backlog_queue {
  my ($webhook_id) = @_;
  my $push         = Bugzilla->push_ext;
  my $webhook_name = 'Webhook_' . $webhook_id;
  my $connector    = $push->connectors->by_name($webhook_name);
  my $queue        = $connector->backlog;
  $queue->delete();
}

#
# Queues
#

sub page_before_template {
  my ($self, $args) = @_;
  my ($vars, $page) = @$args{qw(vars page_id)};
  return unless $page eq 'webhooks_queues.html';
  Bugzilla->params->{webhooks_enabled} || ThrowUserError('webhooks_disabled');
  Bugzilla->user->in_group(Bugzilla->params->{"webhooks_group"})
    || ThrowUserError(
    'auth_failure',
    {
      group  => Bugzilla->params->{"webhooks_group"},
      action => "access",
      object => "webhooks"
    }
    );
  webhooks_queues($vars);
}

sub webhooks_queues {
  my ($vars) = @_;
  my $push   = Bugzilla->push_ext;
  my $input  = Bugzilla->input_params;

  if ($input->{webhook}) {
    my $webhook_name = 'Webhook_' . $input->{webhook};
    my $connector    = $push->connectors->by_name($webhook_name)
      || ThrowUserError('push_error', {error_message => 'Invalid connector'});
    my $webhook = Bugzilla::Extension::Webhooks::Webhook->new($input->{webhook});
    if ($webhook->{user_id} == Bugzilla->user->id) {
      $vars->{connector} = $connector;
      $vars->{webhook}   = $webhook;
    }
    else {
      ThrowUserError('webhooks_wrong_user');
    }
  }

  if ($input->{delete}) {
    my $token = $input->{token};
    check_hash_token($token, ['deleteMessage']);
    my $connector = $push->connectors->by_name($input->{connector})
      || ThrowUserError('push_error', {error_message => 'Invalid connector'});
    my $id = $input->{message} || 0;
    detaint_natural($id)
      || ThrowUserError('push_error', {error_message => 'Invalid message ID'});
    my $message = $connector->backlog->by_id($id)
      || ThrowUserError('push_error', {error_message => 'Invalid message ID'});
    $message->remove_from_db();
    $vars->{message} = 'push_message_deleted';
  }
}

#
# Hooks
#

sub connector_check_error_limit {
  my ($self, $args) = @_;
  my $object = $args->{object};
  my $connector_name = $object->{connector};

  # Disregard if this connector is not a webhook
  return if $connector_name !~ /^Webhook_/;

  # Disregard if we have error limits turned off
  my $error_limit = Bugzilla->params->{webhooks_error_limit};
  return if $error_limit == 0;

  # Disregard if in the error exempt group
  return
   if Bugzilla->user->in_group(Bugzilla->params->{webhooks_error_exempt_group});

  # Disable the webhook and send email to author
  if ($args->{object}->{attempts} >= $error_limit) {
    WARN(
      "WEBHOOK: Disabling connector $connector_name due to large number of errors");

    # Set the connector to be disabled to block new executions
    my $connector = Bugzilla->push_ext->connectors->by_name($connector_name);
    $connector->config->{enabled} = 'Disabled';
    $connector->config->update;

    # Send email notification to author for them to reactivate
    my $webhook
      = Bugzilla::Extension::Webhooks::Webhook->new($connector->{webhook_id});
    my $template = Bugzilla->template_inner($webhook->user->setting('lang'));
    my $vars     = {
      webhook  => $webhook,
      error    => $object->last_error,
      attempts => $object->attempts
    };
    my $message;
    $template->process('email/webhook_disabled.txt.tmpl', $vars, \$message)
      || ThrowTemplateError($template->error);
    MessageToMTA($message);
  }
}

__PACKAGE__->NAME;
