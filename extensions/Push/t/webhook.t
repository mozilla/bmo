#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use 5.10.1;
use strict;
use warnings;
use lib qw( . lib local/lib/perl5 );

use Bugzilla;
BEGIN { Bugzilla->extensions }

use Test2::V0;

use Bugzilla::Test::MockParams (webhooks_enabled => 1);
use Bugzilla::Extension::Push::Connector::Webhook;

{
  package TestWebhookOwner;

  sub can_see_bug     { return 1 }
  sub can_see_product { return 1 }
  sub is_insider      { return 1 }
}

{
  package TestWebhook;

  sub event          { return $_[0]->{event} }
  sub product_name   { return 'Firefox' }
  sub component_name { return 'Any' }
  sub user            { return bless({}, 'TestWebhookOwner') }
}

{
  package TestMessage;

  sub routing_key     { return $_[0]->{routing_key} }
  sub payload_decoded { return $_[0]->{payload} }
}

my $selected_events;
my $connector
  = bless({webhook_id => 1}, 'Bugzilla::Extension::Push::Connector::Webhook');

sub make_payload {
  my ($routing_key, %args) = @_;
  my ($target) = split(/[.]/, $routing_key);

  my $bug = {
    id        => 1,
    product   => $args{product} // 'Firefox',
    component => 'General',
  };
  my $payload = {
    event => {
      target  => $target,
      changes => $args{changes} // [],
    },
  };

  if ($target eq 'bug') {
    $payload->{bug} = $bug;
  }
  else {
    $payload->{$target} = {
      bug        => $bug,
      is_private => 0,
    };
  }

  return $payload;
}

sub should_send {
  my ($events, $routing_key, %args) = @_;
  $selected_events = $events;
  my $message = bless(
    {
      routing_key => $routing_key,
      payload     => make_payload($routing_key, %args),
    },
    'TestMessage'
  );
  return $connector->should_send($message);
}

{
  no warnings qw(redefine once);
  local *Bugzilla::Extension::Webhooks::Webhook::new
    = sub { return bless({event => $selected_events}, 'TestWebhook') };

  my @individual_events = (
    ['create',            'bug.create'],
    ['change',            'bug.modify:summary'],
    ['comment',           'comment.create'],
    ['attachment',        'attachment.create'],
    ['attachment_change', 'attachment.modify:is_obsolete'],
  );

  foreach my $test (@individual_events) {
    my ($event, $routing_key) = @{$test};
    ok(should_send($event, $routing_key), "$event selects $routing_key");
  }

  ok(!should_send('attachment_change', 'bug.modify:summary'),
    'attachment_change does not select bug modifications');
  ok(!should_send('attachment_change', 'attachment.create'),
    'attachment_change does not select new attachments');
  ok(!should_send('attachment', 'attachment.modify:is_obsolete'),
    'attachment does not select attachment modifications');

  ok(should_send('create,comment,attachment_change', 'bug.create'),
    'combined selection includes bug creation');
  ok(should_send('create,comment,attachment_change', 'comment.create'),
    'combined selection includes comments');
  ok(
    should_send(
      'create,comment,attachment_change',
      'attachment.modify:is_obsolete'
    ),
    'combined selection includes attachment modifications'
  );
  ok(!should_send('create,comment,attachment_change', 'attachment.create'),
    'combined selection excludes unselected attachment creation');

  my @product_change = ({field => 'product', removed => 'Firefox'});
  ok(
    should_send(
      'change',
      'bug.modify:product',
      product => 'Thunderbird',
      changes => \@product_change
    ),
    'change selects a bug moved out of the configured product'
  );
  ok(
    !should_send(
      'attachment_change',
      'bug.modify:product',
      product => 'Thunderbird',
      changes => \@product_change
    ),
    'attachment_change does not select a bug moved out of the configured product'
  );
}

done_testing;
