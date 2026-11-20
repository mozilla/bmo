# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::MyDashboard::API::V1::MyDashboard;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla;
use Bugzilla::API::V1::Bug;
use Bugzilla::Bug;
use Bugzilla::Comment;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Template;
use Bugzilla::Util          qw(template_var datetime_from);
use Bugzilla::API::V1::Util qw(merge_request_params render_options);

use Bugzilla::Extension::MyDashboard::Queries
  qw(QUERY_DEFS query_bugs query_flags);
use Bugzilla::Extension::MyDashboard::BugInterest;

sub setup_routes {
  my ($class, $r) = @_;
  my $to = 'MyDashboard::API::V1::MyDashboard#';

  # bug_interest_unmark is also served without the prefix, for backward
  # compatibility; the other methods are newer and always had it.
  $r->put('/bug_interest_unmark')->to($to . 'bug_interest_unmark');
  $r->put('/mydashboard/bug_interest_unmark')->to($to . 'bug_interest_unmark');
  $r->get('/mydashboard/run_bug_query')->to($to . 'run_bug_query');
  $r->get('/mydashboard/run_flag_query')->to($to . 'run_flag_query');
  $r->get('/mydashboard/run_last_changes')->to($to . 'run_last_changes');

  $r->options($_)->to(cb => \&render_options, allow => 'PUT')
    foreach qw(/bug_interest_unmark /mydashboard/bug_interest_unmark);
  $r->options("/mydashboard/$_")->to(cb => \&render_options, allow => 'GET')
    foreach qw(run_bug_query run_flag_query run_last_changes);
}

sub type {
  my ($self, $type, $value) = @_;
  return Bugzilla::API::V1::Util->type($type, $value);
}

# The logged-in user and the request params, or nothing after rendering an
# error.
sub _login {
  my ($self, $lists) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->bugzilla->login;
  if (!$user->id) {
    $self->user_error('login_required');
    return;
  }
  my ($params, $error, $vars) = merge_request_params($self, $lists);
  if ($error) {
    $self->user_error($error, $vars);
    return;
  }
  return ($user, $params);
}

# GET /mydashboard/run_last_changes?bug_id=<id>&changeddate_api=<date>
#
# The last change and the last comment made to the bug after the date.
sub run_last_changes {
  my ($self) = @_;
  my ($user, $params) = $self->_login or return;

  # Only reads from here, as Bug.history did.
  my $dbh = Bugzilla->switch_to_shadow_db();

  my $last_comment_sql = "
        SELECT comment_id
            FROM longdescs
            WHERE bug_id = ? AND bug_when > ?";
  if (!$user->is_insider) {
    $last_comment_sql .= " AND isprivate = 0";
  }
  $last_comment_sql .= " ORDER BY bug_when DESC, comment_id DESC LIMIT 1";
  my $last_comment_sth = $dbh->prepare($last_comment_sql);

  my $last_changes = {};
  my $bug          = Bugzilla::Bug->check($params->{bug_id});
  my ($activity)
    = Bugzilla::Bug::GetBugActivity($bug->id, undef, $params->{changeddate_api},
    1);
  if (@$activity) {
    my $change_set = Bugzilla::API::V1::Bug->changeset_to_hash($activity->[0]);
    $last_changes->{activity} = $change_set->{changes};
    foreach my $change (@{$last_changes->{activity}}) {
      $change->{field_desc} = template_var('field_descs')->{$change->{field_name}}
        || $change->{field_name};
    }
    $last_changes->{email} = $change_set->{who};
    my $datetime = datetime_from($change_set->{when});
    $datetime->set_time_zone($user->timezone);
    $last_changes->{when} = $datetime->strftime('%Y-%m-%d %T %Z');
  }
  my $last_comment_id = $dbh->selectrow_array($last_comment_sth, undef, $bug->id,
    $params->{changeddate_api});
  if ($last_comment_id) {

    # The query above already skips private comments for non-insiders.
    my $comment = Bugzilla::Comment->new($last_comment_id);
    my $text    = $comment->body_full;
    my $html
      = Bugzilla->params->{use_markdown}
      ? Bugzilla->markdown->render_html($text, $bug)
      : Bugzilla::Template::quoteUrls($text, $bug);
    $last_changes->{comment_html} = $html;
    $last_changes->{email}        = $self->type('email', $comment->author->login)
      if !$last_changes->{email};
    my $datetime = datetime_from($comment->creation_ts);
    $datetime->set_time_zone($user->timezone);
    $last_changes->{when} = $datetime->strftime('%Y-%m-%d %T %Z');
  }

  return $self->render(json => {results => [{last_changes => $last_changes}]});
}

# GET /mydashboard/run_bug_query?query=<name>
#
# The bugs of one of the dashboard's queries (QUERY_DEFS).
sub run_bug_query {
  my ($self) = @_;
  my ($user, $params) = $self->_login or return;
  Bugzilla->switch_to_shadow_db();

  defined $params->{query}
    || ThrowCodeError('param_required',
    {function => 'MyDashboard.run_bug_query', param => 'query'});

  my $result;
  foreach my $qdef (QUERY_DEFS) {
    next if $qdef->{name} ne $params->{query};
    my ($bugs, $query_string) = query_bugs($qdef);

    # Add last changes to each bug
    foreach my $b (@$bugs) {

      # Set the data type properly for webservice clients
      # for non-string values.
      $b->{bug_id} = $self->type('int', $b->{bug_id});
    }

    $query_string =~ s/^POSTDATA=&//;
    $qdef->{bugs}   = $bugs;
    $qdef->{buffer} = $query_string;
    $result         = $qdef;
    last;
  }

  return $self->render(json => {result => $result});
}

# GET /mydashboard/run_flag_query?type=<requestee|requester>
#
# The flags requested from or by the user.
sub run_flag_query {
  my ($self) = @_;
  my ($user, $params) = $self->_login or return;
  Bugzilla->switch_to_shadow_db();

  my $type = $params->{type};
  $type
    || ThrowCodeError('param_required',
    {function => 'MyDashboard.run_flag_query', param => 'type'});

  my $results = query_flags($type);

  # Set the data type properly for webservice clients
  # for non-string values.
  foreach my $flag (@$results) {
    $flag->{id}        = $self->type('int',     $flag->{id});
    $flag->{attach_id} = $self->type('int',     $flag->{attach_id});
    $flag->{bug_id}    = $self->type('int',     $flag->{bug_id});
    $flag->{is_patch}  = $self->type('boolean', $flag->{is_patch});
  }

  return $self->render(json => {result => {$type => $results}});
}

# PUT /mydashboard/bug_interest_unmark (or /bug_interest_unmark)
#
# Removes the bugs (bug_ids, one ID or a list) from the user's interest list.
sub bug_interest_unmark {
  my ($self) = @_;
  my ($user, $params) = $self->_login(['bug_ids']) or return;

  ThrowCodeError('param_required',
    {function => 'MyDashboard.bug_interest_unmark', param => 'bug_ids'})
    unless $params->{bug_ids};

  my @bug_ids
    = ref($params->{bug_ids}) ? @{$params->{bug_ids}} : ($params->{bug_ids});

  Bugzilla->dbh->bz_start_transaction();
  foreach my $bug_id (@bug_ids) {
    Bugzilla::Extension::MyDashboard::BugInterest->unmark($user->id, $bug_id);
  }
  Bugzilla->dbh->bz_commit_transaction();

  # The legacy method returned what bz_commit_transaction() did, i.e. 0.
  return $self->render(json => 0);
}

1;
