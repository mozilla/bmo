# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::BugModal;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Extension);

use Bugzilla::Extension::BugModal::ActivityStream;
use Bugzilla::Extension::BugModal::MonkeyPatches;
use Bugzilla::Extension::BugModal::Util qw(date_str_to_time);
use Bugzilla::Constants;
use Bugzilla::Logging;
use Bugzilla::User::Setting;
use Bugzilla::Util qw(datetime_from html_quote time_ago);
use List::MoreUtils qw(any none);
use Template::Stash;
use JSON::XS qw(encode_json);

our $VERSION = '1';

use constant READABLE_BUG_STATUS_PRODUCTS => (
  'Core',            'Toolkit',
  'Firefox',         'Firefox for Android',
  'Firefox for iOS', 'Bugzilla',
  'bugzilla.mozilla.org'
);

sub config_modify_panels {
  my ($self, $args) = @_;
  push @{$args->{panels}->{advanced}->{params}},
    {name => 'use_modal_create', type => 'b', default => '1',};
}

sub enter_bug_format {
  my ($self, $args) = @_;
  my $cgi  = Bugzilla->cgi;

  # Use the modal or custom format unless `format=legacy` is given as a URL param
  my $format = $cgi->param('format') || 'modal';
  $args->{format}
    = $format eq 'legacy' || !Bugzilla->params->{use_modal_create}
    ? ''
    : $format;
}

sub show_bug_format {
  my ($self, $args) = @_;
  $args->{format} = _alternative_show_bug_format();
}

sub edit_bug_format {
  my ($self, $args) = @_;
  $args->{format} = _alternative_show_bug_format();
}

sub _alternative_show_bug_format {
  my $cgi  = Bugzilla->cgi;
  my $user = Bugzilla->user;
  if (my $ctype = $cgi->param('ctype')) {
    return '' if $ctype ne 'html';
  }
  if (my $format = $cgi->param('format')) {
    my @ids = $cgi->param('id');
    # Drop `format=default` as well as `format=multiple`, if a single bug ID is
    # provided, by redirecting to the modal UI (301 Moved Permanently)
    if ($format eq '__default__' || $format eq 'default'
      || ($format eq 'multiple' && scalar(@ids) == 1))
    {
      $cgi->base_redirect('show_bug.cgi?id=' . $cgi->param('id'), 1);
    }
    # Otherwise, printable `format=multiple` is still available from bug lists
    # as the Long Format option
    return $format;
  }
  return 'modal';
}

sub template_after_create {
  my ($self, $args) = @_;
  my $context = $args->{template}->context;

  # wrapper around time_ago()
  $context->define_filter(
    time_duration => sub {
      my ($context) = @_;
      return sub {
        my ($timestamp) = @_;
        my $datetime = datetime_from($timestamp) // return $timestamp;
        return time_ago($datetime);
      };
    },
    1
  );

  # morph a string into one which is suitable to use as an element's id
  $context->define_filter(
    id => sub {
      my ($context) = @_;
      return sub {
        my ($id) = @_;
        $id //= '';
        $id = lc($id);
        while ($id ne '' && $id !~ /^[a-z]/) {
          $id = substr($id, 1);
        }
        $id =~ tr/ /-/;
        $id =~ s/[^a-z\d\-_:\.]/_/g;
        return $id;
      };
    },
    1
  );

  # parse date string and output epoch
  $context->define_filter(
    epoch => sub {
      my ($context) = @_;
      return sub {
        my ($date_str) = @_;
        return date_str_to_time($date_str);
      };
    },
    1
  );

  # flatten a list of hashrefs to a list of values
  # e.g. logins = users.pluck("login")
  $context->define_vmethod(
    list => pluck => sub {
      my ($list, $field) = @_;
      return [map { $_->$field } @$list];
    }
  );

  # returns array where the value in $field does not equal $value
  # opposite of "only"
  # e.g. not_byron = users.skip("name", "Byron")
  $context->define_vmethod(
    list => skip => sub {
      my ($list, $field, $value) = @_;
      return [grep { $_->$field ne $value } @$list];
    }
  );

  # returns array where the value in $field equals $value
  # opposite of "skip"
  # e.g. byrons_only = users.only("name", "Byron")
  $context->define_vmethod(
    list => only => sub {
      my ($list, $field, $value) = @_;
      return [grep { $_->$field eq $value } @$list];
    }
  );

  # returns boolean indicating if the value exists in the list
  # e.g. has_byron = user_names.exists("byron")
  $context->define_vmethod(
    list => exists => sub {
      my ($list, $value) = @_;
      return any { $_ eq $value } @$list;
    }
  );

  # ucfirst is only available in new template::toolkit versions
  $context->define_vmethod(
    item => ucfirst => sub {
      my ($text) = @_;
      return ucfirst($text);
    }
  );
}

sub template_before_process {
  my ($self, $args) = @_;
  my $file = $args->{file};
  my $vars = $args->{vars};

  return if $file ne 'bug_modal/header.html.tmpl';

  if ($vars->{bug} && !$vars->{bugs}) {
    $vars->{bugs} = [$vars->{bug}];
  }

  return
       unless $vars->{bugs}
    && ref($vars->{bugs}) eq 'ARRAY'
    && scalar(@{$vars->{bugs}}) == 1;
  my $bug = $vars->{bugs}->[0];
  return if exists $bug->{error};

  # trigger loading of tracking flags
  Bugzilla::Extension::TrackingFlags->template_before_process({
    file => 'bug/edit.html.tmpl', vars => $vars,
  });

  if (any { $bug->product eq $_ } READABLE_BUG_STATUS_PRODUCTS) {
    my @flags = map { {name => $_->name, status => $_->status} } @{$bug->flags};
    $vars->{readable_bug_status_json} = encode_json({
      dupe_of          => $bug->dup_id,
      id               => $bug->id,
      keywords         => [map { $_->name } @{$bug->keyword_objects}],
      priority         => $bug->priority,
      resolution       => $bug->resolution,
      status           => $bug->bug_status,
      flags            => \@flags,
      target_milestone => $bug->target_milestone,
      map { $_->name => $_->bug_flag($bug->id)->value } @{$vars->{tracking_flags}},
    });

    # HTML4 attributes cannot be longer than this, so just skip it in this case.
    if (length($vars->{readable_bug_status_json}) > 65536) {
      delete $vars->{readable_bug_status_json};
    }
  }

  # bug->choices loads a lot of data that we want to lazy-load
  # just load the status and resolutions and perform extra checks here
  # upstream does these checks in the bug/fields template
  my $perms = $bug->user;
  my @resolutions;
  foreach my $r (
    @{Bugzilla::Field->new({name => 'resolution', cache => 1})->legal_values})
  {
    my $resolution = $r->name;
    next unless $resolution;

    # always allow the current value
    if ($resolution eq $bug->resolution) {
      push @resolutions, $r;
      next;
    }

    # never allow inactive values
    next unless $r->is_active;

    # ensure the user has basic rights to change this field
    my $can_change = $bug->check_can_change_field('resolution', '---', $resolution);
    next unless $can_change->{allowed};

    # canconfirm users can only set the resolution to WFM, INCOMPLETE or DUPE
    if ($perms->{canconfirm} && !($perms->{canedit} || $perms->{isreporter})) {
      next
        if $resolution ne 'WORKSFORME'
        && $resolution ne 'INCOMPLETE'
        && $resolution ne 'DUPLICATE';
    }

    # reporters can set it to anything, except INCOMPLETE
    if ($perms->{isreporter} && !($perms->{canconfirm} || $perms->{canedit})) {
      next if $resolution eq 'INCOMPLETE';
    }

    # expired has, uh, expired
    next if $resolution eq 'EXPIRED';

    push @resolutions, $r;
  }
  $bug->{choices} = {
    bug_status => [
      grep { $_->is_active || $_->name eq $bug->bug_status }
        @{$bug->statuses_available}
    ],
    resolution => \@resolutions,
  };

  # Log tracking flags
  _log_tracking_flags($bug, $vars->{tracking_flags});

  # for the "View -> Hide Treeherder Comments" menu item
  my @treeherder_ids = map { $_->id } @{Bugzilla->treeherder_users};
  foreach my $change_set (@{$bug->activity_stream}) {
    if (
      $change_set->{comment} && any { $change_set->{comment}->author->id == $_ }
      @treeherder_ids
      )
    {
      $vars->{treeherder_user_ids} = \@treeherder_ids;
      last;
    }
  }
}

sub bug_start_of_set_all {
  my ($self, $args) = @_;
  my $bug    = $args->{bug};
  my $params = $args->{params};

  # reset to the component defaults if not supplied
  if (exists $params->{assigned_to}
    && (!defined $params->{assigned_to} || $params->{assigned_to} eq ''))
  {
    $params->{assigned_to} = $bug->component_obj->default_assignee->login;
  }
  if ( exists $params->{qa_contact}
    && (!defined $params->{qa_contact} || $params->{qa_contact} eq '')
    && $bug->component_obj->default_qa_contact->id)
  {
    $params->{qa_contact} = $bug->component_obj->default_qa_contact->login;
  }
}

sub install_before_final_checks {
  my ($self, $args) = @_;
  remove_setting('ui_experiments');
  add_setting({
    name     => 'ui_remember_collapsed',
    options  => ['on', 'off'],
    default  => 'off',
    category => 'User Interface'
  });
  add_setting({
    name     => 'ui_use_absolute_time',
    options  => ['on', 'off'],
    default  => 'off',
    category => 'User Interface',
  });
  add_setting({
    name     => 'ui_attach_long_paste',
    options  => ['on', 'off'],
    default  => 'on',
    category => 'User Interface',
  });
  add_setting({
    name     => 'ui_show_comment_reactions',
    options  => ['on', 'off'],
    default  => 'on',
    category => 'User Interface',
  });
}

sub editable_tables {
  my ($self, $args) = @_;
  my $tables = $args->{tables};

  # allow table to be edited with the EditTables extension
  $tables->{longdescs_tags_url} = {
    id_field => 'id',
    order_by => 'tag',
    blurb =>
      'List of comment tags that have a URL associated with them for further information.',
    group => 'admin',
  };
}

sub _log_tracking_flags {
  my ($bug, $flags) = @_;
  my $user = Bugzilla->user;

  # Load my own copy of Bug from the DB cause I want to be sure
  # it is untainted
  my $bug_obj = Bugzilla::Bug->new($bug->id);

  # If the bug currently does not have any flags set to fixed in 
  # the DB, but yet the flag data has values set to fixed, then 
  # we need to log detailed data. We will key off of the 
  # cf_status_thunderbird_esr91 flags since it is consistently 
  # included in the erroneous changes.
  if (!$bug->can('cf_status_thunderbird_esr91')
    || $bug->cf_status_thunderbird_esr91 ne '---')
  {
    return undef;
  }

  if (
    none {
      $_->name eq 'cf_status_thunderbird_esr91' && $_->bug_flag->value eq 'fixed'
    } @{$flags}
    )
  {
    return undef;
  }

  my $log_data = {
    user  => {id => $user->id, login => $user->login,},
    flags => [map { _flag_to_hash($_) } @{$flags}]
  };

  WARN(encode_json $log_data);
}

sub _flag_to_hash {
  my $flag = shift;
  return {
    id          => $flag->flag_id,
    name        => $flag->name,
    description => $flag->description,
    type        => $flag->flag_type,
    values      => [map { $_->name } @{$flag->values}],
    bug_flag    =>
      {bug_id => $flag->bug_flag->bug_id, value => $flag->bug_flag->value,}
  };
}

__PACKAGE__->NAME;
