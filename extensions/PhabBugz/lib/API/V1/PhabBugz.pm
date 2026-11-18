# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz::API::V1::PhabBugz;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Group;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::Util qw(trim);

use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Revision;
use Bugzilla::Extension::PhabBugz::Util qw(request);
use Bugzilla::Extension::TrackingFlags::Flag;

use List::Util      qw(uniq);
use Types::Standard qw(-types slurpy);

our %api_field_names = reverse %{Bugzilla::Bug::FIELD_MAP()};
$api_field_names{'bug_group'} = 'groups';

sub setup_routes {
  my ($class, $r) = @_;

  # Lando automation related endpoints
  $r->get('/lando/uplift')->to('PhabBugz::API::V1::PhabBugz#get_bugs');
  $r->get('/lando/uplift/:id')->to('PhabBugz::API::V1::PhabBugz#get_bugs');
  $r->put('/lando/uplift')->to('PhabBugz::API::V1::PhabBugz#update_bugs');

  # Pulsebot automation related endpoints
  $r->get('/pulsebot/bug')->to('PhabBugz::API::V1::PhabBugz#get_bugs');
  $r->get('/pulsebot/bug/:id')->to('PhabBugz::API::V1::PhabBugz#get_bugs');
  $r->get('/pulsebot/bug/:id/comment')
    ->to('PhabBugz::API::V1::PhabBugz#get_comments');
  $r->post('/pulsebot/bug/:id/comment')
    ->to('PhabBugz::API::V1::PhabBugz#add_comment');
  $r->put('/pulsebot/bug')->to('PhabBugz::API::V1::PhabBugz#update_bugs');

  # Bug permission checks, for Phabricator
  $r->get('/phabbugz/check_bug/:bug_id/:user_id' =>
      [bug_id => qr/\d+/, user_id => qr/\d+/])
    ->to('PhabBugz::API::V1::PhabBugz#check_user_permission_for_bug');
  $r->get('/phabbugz/check_enter_bug/#product/:user_id' => [user_id => qr/\d+/])
    ->to('PhabBugz::API::V1::PhabBugz#check_user_enter_bug_permission');

  # Revisions and Phabricator accounts, for the bug page and user profiles
  $r->get('/phabbugz/bug_revisions/:bug_id' => [bug_id => qr/\d+/])
    ->to('PhabBugz::API::V1::PhabBugz#bug_revisions');
  $r->get('/phabbugz/user/:user_id' => [user_id => qr/\d+/])
    ->to('PhabBugz::API::V1::PhabBugz#user');
}

sub get_bugs {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # Must be permitted automation user to access this endpoint
  if ( $user->login ne LANDO_AUTOMATION_USER
    && $user->login ne PULSEBOT_AUTOMATION_USER)
  {
    return $self->user_error('login_required');
  }

  # Upgrade user permissions to make changes to any bug
  $user->{groups}       = [Bugzilla::Group->get_all];
  $user->{bless_groups} = [Bugzilla::Group->get_all];

  my @ids = split /,/, $self->param('id');
  @ids || ThrowCodeError('param_required', {param => 'id'});

  my @results;
  foreach my $id (@ids) {
    my $bug = Bugzilla::Bug->check($id);

    my $result = {
      id         => $bug->id,
      keywords   => [map { $_->name } @{$bug->keyword_objects}],
      whiteboard => $bug->status_whiteboard,
    };

    if ($user->login eq LANDO_AUTOMATION_USER) {
      my $flags = Bugzilla::Extension::TrackingFlags::Flag->match(
        {bug_id => $bug->id, is_active => 1});
      foreach my $flag (@{$flags}) {
        my $flag_name = $flag->name;
        $result->{$flag_name} = $bug->$flag_name;
      }
    }

    if ($user->login eq PULSEBOT_AUTOMATION_USER) {
      $result->{status} = $bug->bug_status;
    }

    push @results, $result;
  }

  $self->render(json => {bugs => \@results});
}

sub get_comments {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # Must be permitted automation user to access this endpoint
  if ($user->login ne PULSEBOT_AUTOMATION_USER) {
    return $self->user_error('login_required');
  }

  # Upgrade user permissions to retrieve comment for any bug
  $user->{groups}       = [Bugzilla::Group->get_all];
  $user->{bless_groups} = [Bugzilla::Group->get_all];

  $self->param('id') || ThrowCodeError('param_required', {param => 'id'});

  my $bug = Bugzilla::Bug->check($self->param('id'));

  my $comments = $bug->comments({order => 'oldest_to_newest'});

  # Only return the comment text and the comment tags
  my @result;
  foreach my $comment (@$comments) {
    next if $comment->is_private;
    push @result, {
      id   => $comment->id,
      tags => $comment->tags,
      text => $comment->body_full
    };
  }

  $self->render(json => {bugs => {$bug->id => {comments => \@result}}});
}

sub add_comment {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # Must be permitted automation user to access this endpoint
  if ($user->login ne PULSEBOT_AUTOMATION_USER) {
    return $self->user_error('login_required');
  }

  # Upgrade user permissions to add a comment to any bug
  $user->{groups}       = [Bugzilla::Group->get_all];
  $user->{bless_groups} = [Bugzilla::Group->get_all];

  $self->param('id') || ThrowCodeError('param_required', {param => 'id'});

  my $json_params = $self->req->json;

  my $comment = $json_params->{comment};
  (defined $comment && trim($comment) ne '')
    || ThrowCodeError('param_required', {param => 'comment'});

  my $bug = Bugzilla::Bug->check($self->param('id'));

  # Append comment
  $bug->add_comment($comment);

  # Allow setting of comment tags such as an uplift revision comment
  if ($json_params->{comment_tags}) {
    $bug->set_all({comment_tags => $json_params->{comment_tags}});
  }

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction();

  $bug->update();

  my $new_comment_id = $dbh->bz_last_key('longdescs', 'comment_id');

  $dbh->bz_commit_transaction();

  # Send mail.
  Bugzilla::BugMail::Send($bug->bug_id, {changer => Bugzilla->user});

  $self->render(json => {id => $new_comment_id});
}

sub update_bugs {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  # Must be permitted automation user to access this endpoint
  if ( $user->login ne LANDO_AUTOMATION_USER
    && $user->login ne PULSEBOT_AUTOMATION_USER)
  {
    return $self->user_error('login_required');
  }

  # Upgrade user permissions to make changes to any bug
  $user->{groups}       = [Bugzilla::Group->get_all];
  $user->{bless_groups} = [Bugzilla::Group->get_all];

  my $params = $self->req->json;
  $params = Bugzilla::Bug::map_fields($params);

  my $ids = delete $params->{ids};
  defined $ids || return $self->code_error('param_required', {param => 'ids'});

  my @bugs = map { Bugzilla::Bug->check($_) } @{$ids};

  my @allowed_fields;
  if ($user->login eq LANDO_AUTOMATION_USER) {
    @allowed_fields = LANDO_BUG_UPDATE_FIELDS;
  }
  if ($user->login eq PULSEBOT_AUTOMATION_USER) {
    @allowed_fields = PULSEBOT_BUG_UPDATE_FIELDS;
  }

  # Strictly prohibit the user from changing any fields
  # other than ones allowed for the user. 
  my $allowed_params = {};
  foreach my $param (keys %{$params}) {
    foreach my $field (@allowed_fields) {
      # We handle custom fields differently by using a regexp match
      if (($param =~ /^cf_/ && $field =~ /^cf_/ && $param =~ /^$field/) || $param eq $field) {
        $allowed_params->{$param} = delete $params->{$param};
        last;
      }
    }
  }

  # If any additional parameters were passed then we will throw an error
  if (%{$params}) {
    return $self->code_error('too_many_params',
      {allowed_params => \@allowed_fields});
  }

  # Update each bug
  foreach my $bug (@bugs) {
    $bug->set_all($allowed_params);
  }

  my %all_changes;

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction();
  foreach my $bug (@bugs) {
    $all_changes{$bug->id} = $bug->update();
  }
  $dbh->bz_commit_transaction();

  foreach my $bug (@bugs) {
    $bug->send_changes($all_changes{$bug->id});
  }

  my @result;
  foreach my $bug (@bugs) {
    my %hash = (id => $bug->id, last_change_time => $bug->delta_ts, changes => {},);
    my %changes = %{$all_changes{$bug->id}};
    foreach my $field (keys %changes) {
      my $change    = $changes{$field};
      my $api_field = $api_field_names{$field} || $field;
      $change->[0] = '' if !defined $change->[0];
      $change->[1] = '' if !defined $change->[1];
      $hash{changes}->{$api_field}
        = {removed => $change->[0], added => $change->[1],};
    }
    push @result, \%hash;
  }

  $self->render(json => {bugs => \@result});
}

sub _check_phabricator {

  # Ensure PhabBugz is on
  ThrowUserError('phabricator_not_enabled')
    unless Bugzilla->params->{phabricator_enabled};
}

sub _validate_phab_user {
  my ($self, $user) = @_;

  $self->_check_phabricator();

  # Validate that the requesting user's email matches phab-bot
  ThrowUserError('phabricator_unauthorized_user')
    unless $user->login eq PHAB_AUTOMATION_USER;
}

# The logged-in user, or undef after rendering a login_required error.
sub _login {
  my ($self) = @_;
  my $user = $self->bugzilla->login;
  return $user if $user->id;
  $self->user_error('login_required');
  return undef;
}

# GET /phabbugz/check_bug/<bug_id>/<user_id>
#
# phab-bot only. {result => 1} if the user can see the bug, else 0.
sub check_user_permission_for_bug {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->_login || return;
  Bugzilla->switch_to_shadow_db();

  $self->_validate_phab_user($user);

  my $bug_id  = $self->param('bug_id');
  my $user_id = $self->param('user_id');

  # Validate that a bug id and user id are provided
  ThrowUserError('phabricator_invalid_request_params')
    unless ($bug_id && $user_id);

  # Validate that the user exists
  my $target_user = Bugzilla::User->check({id => $user_id, cache => 1});

  # Send back an object which says { "result": 1|0 }
  return $self->render(json => {result => $target_user->can_see_bug($bug_id)});
}

# GET /phabbugz/check_enter_bug/<product>/<user_id>
#
# phab-bot only. {result => 1} if the user can file bugs in the product,
# else 0.
sub check_user_enter_bug_permission {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);
  my $user = $self->_login || return;
  Bugzilla->switch_to_shadow_db();

  $self->_validate_phab_user($user);

  my $product = $self->param('product');
  my $user_id = $self->param('user_id');

  # Validate that a product name and user id are provided
  ThrowUserError('phabricator_invalid_request_params')
    unless ($product && $user_id);

  # Validate that the user exists
  my $target_user = Bugzilla::User->check({id => $user_id, cache => 1});

  # Send back an object with the attribute "result" set to 1 if the user
  # can enter bugs into the given product, or 0 if not.
  return $self->render(
    json => {result => $target_user->can_enter_product($product) ? 1 : 0});
}

# GET /phabbugz/bug_revisions/<bug_id>
#
# The Phabricator revisions attached to the bug, sorted by id, with their
# reviews and stack children. Titles of non-public revisions are hidden.
sub bug_revisions {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  $self->_check_phabricator();

  my $user = $self->_login || return;
  Bugzilla->switch_to_shadow_db();

  my $bug_id = $self->param('bug_id');

  # Validate that a bug id and user id are provided
  ThrowUserError('phabricator_invalid_request_params') unless $bug_id;

  # Validate that the user can see the bug itself
  my $bug = Bugzilla::Bug->check({id => $bug_id, cache => 1});

  my @revision_ids;
  foreach my $attachment (@{$bug->attachments}) {
    next if $attachment->contenttype ne PHAB_CONTENT_TYPE;
    my ($revision_id) = ($attachment->filename =~ PHAB_ATTACHMENT_PATTERN);
    next if !$revision_id;
    push @revision_ids, int $revision_id;
  }

  my $response = request(
    'differential.revision.search',
    {
      attachments => {
        'projects'        => 1,
        'reviewers'       => 1,
        'subscribers'     => 1,
        'reviewers-extra' => 1,
      },
      constraints => {ids => \@revision_ids,},
      order       => 'newest',
    }
  );

  state $SearchResult = Dict [
    result => Dict [

      # HashRef below could be better,
      # but ::Revision takes a lot of options.
      data => ArrayRef [HashRef],
      slurpy Any,
    ],
    slurpy Any,
  ];

  my $error = $SearchResult->validate($response);
  ThrowCodeError('phabricator_api_error', {reason => $error}) if defined $error;

  my $children_map = $self->_get_children_map($response);

  my $revision_status_map = {
    'abandoned'       => 'Abandoned',
    'accepted'        => 'Accepted',
    'changes-planned' => 'Changes Planned',
    'draft'           => 'Draft',
    'needs-review'    => 'Needs Review',
    'needs-revision'  => 'Needs Revision',
  };

  my $review_status_map = {
    'accepted'       => 'Accepted',
    'accepted-prior' => 'Accepted Prior Diff',
    'added'          => 'Review Requested',
    'blocking'       => 'Blocking Review',
    'rejected'       => 'Requested Changes',
    'resigned'       => 'Resigned'
  };

  my @revisions;
  foreach my $revision (@{$response->{result}{data}}) {

    # Skip if revision bug id was moved to a different bug
    next if $revision->{fields}->{'bugzilla.bug-id'} ne $bug->id;

    my $revision_obj  = Bugzilla::Extension::PhabBugz::Revision->new($revision);
    my $id            = $revision_obj->id;
    my $revision_data = {
      id          => 'D' . $id,
      sortkey     => $id,
      status      => $revision_obj->status,
      long_status => $revision_status_map->{$revision_obj->status}
        || $revision_obj->status
    };

    my @reviews;
    foreach my $review (@{$revision_obj->reviews}) {
      push @reviews,
        {
        user        => $review->{user}->name,
        status      => $review->{status},
        long_status => $review_status_map->{$review->{status}} || $review->{status}
        };
    }
    $revision_data->{reviews} = \@reviews;

    if ($revision_obj->view_policy ne 'public') {
      $revision_data->{title}     = '(secured)';
      $revision_data->{call_sign} = '(secured)';
    }
    else {
      $revision_data->{title} = $revision_obj->title;
      $revision_data->{call_sign}
        = $revision_obj->repository ? $revision_obj->repository->call_sign : 'N/A';
    }

    $revision_data->{children} = [map {"D$_"} @{$children_map->{$id}}];

    push @revisions, $revision_data;
  }

  # sort by revision id
  @revisions = sort { $a->{sortkey} <=> $b->{sortkey} } @revisions;

  return $self->render(json => {revisions => \@revisions});
}

sub _get_children_map {
  my ($self, $revisions_response) = @_;

  my @revision_phids;
  foreach my $revision (@{$revisions_response->{result}{data}}) {
    push @revision_phids, $revision->{phid};
  }

  my $edge_response = request('edge.search',
    {sourcePHIDs => \@revision_phids, types => ["revision.child"],});

  my $rev_phid_to_id = {};
  my $children_map   = {};
  foreach my $revision (@{$revisions_response->{result}{data}}) {
    my $id   = $revision->{id};
    my $phid = $revision->{phid};
    $rev_phid_to_id->{$phid} = $id;
    $children_map->{$id}     = [];
  }

  foreach my $edge (@{$edge_response->{result}{data}}) {
    if (!exists($rev_phid_to_id->{$edge->{sourcePHID}})) {
      next;
    }
    if (!exists($rev_phid_to_id->{$edge->{destinationPHID}})) {
      next;
    }

    my $from = $rev_phid_to_id->{$edge->{sourcePHID}};
    my $to   = $rev_phid_to_id->{$edge->{destinationPHID}};

    if (!exists($children_map->{$from})) {
      next;
    }

    push @{$children_map->{$from}}, $to;
  }

  return $children_map;
}

# GET /phabbugz/user/<user_id>
#
# The Phabricator account linked to the BMO user, with links to its profile
# and open revisions, or {} if there is none.
sub user {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  $self->_check_phabricator();

  $self->_login || return;

  my $bmo_user_id = $self->param('user_id');

  my $response
    = request('bmoexternalaccount.search', {accountids => [$bmo_user_id],});
  if (scalar(@{$response->{result}}) == 0) {
    return $self->render(json => {});
  }

  my $phid = $response->{result}[0]{phid};

  $response = request('user.query', {phids => [$phid],});
  if (scalar(@{$response->{result}}) == 0) {
    return $self->render(json => {});
  }

  my $user_name = $response->{result}[0]{userName};
  my $real_name = $response->{result}[0]{realName};

  my $base_url = Bugzilla->params->{phabricator_base_uri};
  $base_url =~ s{/$}{};
  my $user_url = "$base_url/p/$user_name/";
  my $revisions_url
    = "$base_url/differential/?responsiblePHIDs%5B0%5D=$phid&statuses%5B0%5D=open()&order=newest&bucket=action";

  return $self->render(
    json => {
      user => {
        phid         => $phid,
        userName     => $user_name,
        realName     => $real_name,
        userURL      => $user_url,
        revisionsURL => $revisions_url,
      },
    }
  );
}

1;
