# This Source Code Form is hasject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz::Revision;

use 5.10.1;
use Moo;

use Digest::SHA qw(sha1_hex);
use Mojo::JSON qw(encode_json true);
use Scalar::Util qw(blessed weaken);
use Types::Standard -all;
use Type::Utils;

use Bugzilla::Bug;
use Bugzilla::Logging;
use Bugzilla::Types qw(JSONBool);
use Bugzilla::Error;
use Bugzilla::Util qw(trim);
use Bugzilla::Extension::PhabBugz::Comment;
use Bugzilla::Extension::PhabBugz::Project;
use Bugzilla::Extension::PhabBugz::Repository;
use Bugzilla::Extension::PhabBugz::Types qw(:types);
use Bugzilla::Extension::PhabBugz::User;
use Bugzilla::Extension::PhabBugz::Util qw(remove_noop_transactions request);

#########################
#    Initialization     #
#########################

has id               => (is => 'ro',   isa => Int);
has phid             => (is => 'ro',   isa => Str);
has title            => (is => 'ro',   isa => Str);
has summary          => (is => 'ro',   isa => Str);
has status           => (is => 'ro',   isa => Str);
has is_draft         => (is => 'ro',   isa => Bool | JSONBool);
has hold_as_draft    => (is => 'ro',   isa => Bool | JSONBool);
has creation_ts      => (is => 'ro',   isa => Str);
has modification_ts  => (is => 'ro',   isa => Str);
has author_phid      => (is => 'ro',   isa => Str);
has diff_phid        => (is => 'ro',   isa => Str);
has repository_phid  => (is => 'ro',   isa => Maybe[Str]);
has bug_id           => (is => 'ro',   isa => Str);
has view_policy      => (is => 'ro',   isa => Str);
has edit_policy      => (is => 'ro',   isa => Str);
has stack_graph_raw  => (
    is => 'ro',
    isa => Maybe [
      Dict [
          slurpy Any
      ]
    ],
);
has subscriber_count => (is => 'ro',   isa => Int);
has bug              => (is => 'lazy', isa => Object);
has uplift_request   => (is => 'ro',   isa => Maybe[ArrayRef | Dict [ slurpy Any ]]);
has author           => (is => 'lazy', isa => Object);
has repository       => (is => 'lazy', isa => Maybe[PhabRepo]);
has reviews => (
  is  => 'lazy',
  isa => ArrayRef [
    Dict [
      user        => PhabUser | PhabProject,
      status      => Str,
      is_blocking => Bool,
      is_project  => Bool
    ]
  ]
);
has subscribers => (is => 'lazy', isa => ArrayRef [PhabUser]);
has projects    => (is => 'lazy', isa => ArrayRef [Project]);
has reviewers_raw => (
  is  => 'ro',
  isa => ArrayRef [
    Dict [
      reviewerPHID => Str,
      status       => Str,
      isBlocking   => Bool | JSONBool,
      actorPHID    => Maybe [Str],
    ],
  ]
);
has subscribers_raw => (
  is  => 'ro',
  isa => Dict [
    subscriberPHIDs    => ArrayRef [Str],
    subscriberCount    => Int,
    viewerIsSubscribed => Bool | JSONBool,
  ]
);
has projects_raw => (is => 'ro', isa => Dict [projectPHIDs => ArrayRef [Str]]);
has reviewers_extra_raw => (
  is  => 'ro',
  isa => ArrayRef [
    Dict [reviewerPHID => Str, voidedPHID => Maybe [Str], diffPHID => Maybe [Str]]
  ]
);
has stack_graph => (is => 'lazy');
has comments => (is => 'lazy');

sub new_from_query {
  my ($class, $params) = @_;

  my $data = {
    queryKey    => 'all',
    attachments => {projects => 1, reviewers => 1, subscribers => 1},
    constraints => $params
  };

  my $result = request('differential.revision.search', $data);
  if (exists $result->{result}{data} && @{$result->{result}{data}}) {
    $result = $result->{result}{data}[0];

    # Some values in Phabricator for bug ids may have been saved
    # white whitespace so we remove any here just in case.
    $result->{fields}->{'bugzilla.bug-id'}
      = $result->{fields}->{'bugzilla.bug-id'}
      ? trim($result->{fields}->{'bugzilla.bug-id'})
      : "";
    return $class->new($result);
  }

  return undef;
}

sub BUILDARGS {
  my ($class, $params) = @_;

  $params->{title}           = $params->{fields}->{title};
  $params->{summary}         = $params->{fields}->{summary};
  $params->{status}          = $params->{fields}->{status}->{value};
  $params->{is_draft}        = $params->{fields}->{isDraft};
  $params->{hold_as_draft}   = $params->{fields}->{holdAsDraft};
  $params->{creation_ts}     = $params->{fields}->{dateCreated};
  $params->{modification_ts} = $params->{fields}->{dateModified};
  $params->{author_phid}     = $params->{fields}->{authorPHID};
  $params->{diff_phid}       = $params->{fields}->{diffPHID};
  $params->{repository_phid} = $params->{fields}->{repositoryPHID};
  $params->{bug_id}          = $params->{fields}->{'bugzilla.bug-id'};
  $params->{uplift_request}  = $params->{fields}->{'uplift.request'};
  $params->{view_policy}     = $params->{fields}->{policy}->{view};
  $params->{edit_policy}     = $params->{fields}->{policy}->{edit};
  $params->{stack_graph_raw} = $params->{fields}->{stackGraph};
  $params->{reviewers_raw}   = $params->{attachments}->{reviewers}->{reviewers}
    // [];
  $params->{subscribers_raw} = $params->{attachments}->{subscribers};
  $params->{projects_raw}    = $params->{attachments}->{projects};
  $params->{reviewers_extra_raw}
    = $params->{attachments}->{'reviewers-extra'}->{'reviewers-extra'} // [];
  $params->{subscriber_count}
    = $params->{attachments}->{subscribers}->{subscriberCount};

  delete $params->{fields};
  delete $params->{attachments};

  return $params;
}

# {
#   "data": [
#     {
#       "id": 25,
#       "type": "DREV",
#       "phid": "PHID-DREV-uozm3ggfp7e7uoqegmc3",
#       "fields": {
#         "stackGraph": {
#           "PHID-DREV-tzccv6pxtghpdkeutys2": [
#             "PHID-DREV-rqndonx3itqv3ykz7tn6"
#           ],
#           "PHID-DREV-rqndonx3itqv3ykz7tn6": [
#             "PHID-DREV-5jxsanssnzmhdtgxa33x"
#           ],
#           "PHID-DREV-5jxsanssnzmhdtgxa33x": []
#         },
#         "title": "Added .arcconfig",
#         "authorPHID": "PHID-USER-4wigy3sh5fc5t74vapwm",
#         "dateCreated": 1507666113,
#         "dateModified": 1508514027,
#         "policy": {
#           "view": "public",
#           "edit": "admin"
#         },
#         "bugzilla.bug-id": "1154784",
#         "uplift.request": {
#             "User impact if declined": "Some impact.",
#             "Code covered by automated testing": true,
#             "Fix verified in Nightly": true,
#             "Needs manual QE test": false,
#             "Steps to reproduce for manual QE testing": "none",
#             "Risk associated with taking this patch": "low",
#             "Explanation of risk level": "Affects only nondefault configurations.",
#             "String changes made/needed": "none",
#             "Is Android affected?": true
#         }
#       },
#       "attachments": {
#         "reviewers": {
#           "reviewers": [
#             {
#               "reviewerPHID": "PHID-USER-2gjdpu7thmpjxxnp7tjq",
#               "status": "added",
#               "isBlocking": false,
#               "actorPHID": null
#             },
#             {
#               "reviewerPHID": "PHID-USER-o5dnet6dp4dkxkg5b3ox",
#               "status": "rejected",
#               "isBlocking": false,
#               "actorPHID": "PHID-USER-o5dnet6dp4dkxkg5b3ox"
#             }
#           ]
#         },
#         "subscribers": {
#           "subscriberPHIDs": [],
#           "subscriberCount": 0,
#           "viewerIsSubscribed": true
#         },
#         "projects": {
#           "projectPHIDs": []
#         }
#       }
#     }
#   ],
#   "maps": {},
#   "query": {
#     "queryKey": null
#   },
#   "cursor": {
#     "limit": 100,
#     "after": null,
#     "before": null,
#     "order": null
#   }
# }

#########################
#     Modification      #
#########################

sub update {
  my ($self) = @_;

  my $data = {objectIdentifier => $self->phid, transactions => []};

  if ($self->{added_comments}) {
    foreach my $comment (@{$self->{added_comments}}) {
      push @{$data->{transactions}}, {type => 'comment', value => $comment};
    }
  }

  if ($self->{set_subscribers}) {
    push @{$data->{transactions}},
      {type => 'subscribers.set', value => $self->{set_subscribers}};
  }

  if ($self->{add_subscribers}) {
    push @{$data->{transactions}},
      {type => 'subscribers.add', value => $self->{add_subscribers}};
  }

  if ($self->{remove_subscribers}) {
    push @{$data->{transactions}},
      {type => 'subscribers.remove', value => $self->{remove_subscribers}};
  }

  if ($self->{set_reviewers}) {
    push @{$data->{transactions}},
      {type => 'reviewers.set', value => $self->{set_reviewers}};
  }

  if ($self->{add_reviewers}) {
    push @{$data->{transactions}},
      {type => 'reviewers.add', value => $self->{add_reviewers}};
  }

  if ($self->{remove_reviewers}) {
    push @{$data->{transactions}},
      {type => 'reviewers.remove', value => $self->{remove_reviewers}};
  }

  if ($self->{set_policy}) {
    foreach my $name ("view", "edit") {
      next unless $self->{set_policy}->{$name};
      push @{$data->{transactions}},
        {type => $name, value => $self->{set_policy}->{$name}};
    }
  }

  if ($self->{set_status}) {
    push(@{$data->{transactions}}, {type => $self->{set_status}, value => true});
  }

  if ($self->{add_projects}) {
    push(
      @{$data->{transactions}},
      {type => 'projects.add', value => $self->{add_projects}}
    );
  }

  if ($self->{remove_projects}) {
    push(
      @{$data->{transactions}},
      {type => 'projects.remove', value => $self->{remove_projects}}
    );
  }

  # Phabricator records an edit, and bumps the revision's modified date, even
  # when no transactions are sent, so only call Conduit if something changed.
  $data->{transactions} = remove_noop_transactions($data->{transactions});
  return undef unless @{$data->{transactions}};

  my $result = request('differential.revision.edit', $data);

  return $result;
}

#########################
#      Accessors        #
#########################

sub secured_title {
  my ($self) = @_;
  return $self->is_private ? '(secure)' : $self->title;
}

sub uplift_hash {
  my ($self) = @_;

  # Mojo's `encode_json` should sort keys by default.
  my $uplift_json_encoded = encode_json($self->uplift_request);
  return sha1_hex($uplift_json_encoded);
}

#########################
#      Builders         #
#########################

sub _build_bug {
  my ($self) = @_;
  my $bug = $self->{bug} ||= Bugzilla::Bug->new({id => $self->bug_id, cache => 1});
  weaken($self->{bug});
  return $bug;
}

sub _build_author {
  my ($self) = @_;
  return $self->{author} if $self->{author};
  my $phab_user
    = Bugzilla::Extension::PhabBugz::User->new_from_query({
    phids => [$self->author_phid]
    });
  if ($phab_user) {
    return $self->{author} = $phab_user;
  }
}

sub _build_reviews {
  my ($self) = @_;

  my @reviewers;
  foreach my $raw (@{$self->reviewers_raw}) {
    # Only interests in user or project objects (would there ever be something else?)
    my $reviewer_phid = $raw->{reviewerPHID};
    next if $reviewer_phid !~ /^PHID-(?:PROJ|USER)/;

    my $reviewer_data = {
      is_blocking => ($raw->{isBlocking} ? 1 : 0),
      is_project  => 0,
      status      => $raw->{status},
    };

    if ($reviewer_phid =~ /^PHID-PROJ/) {
      $reviewer_data->{user} = Bugzilla::Extension::PhabBugz::Project->new_from_query({phids => [$reviewer_phid]});
      $reviewer_data->{is_project} = 1;
    }
    elsif ($reviewer_phid =~ /^PHID-USER/) {
      $reviewer_data->{user} = Bugzilla::Extension::PhabBugz::User->new_from_query({phids => [$reviewer_phid]});
    }

    next if !$reviewer_data->{user}; # Skip if user or project was not found.

    # Set to accepted-prior if the diffs reviewer are different and the reviewer status is accepted
    foreach my $reviewer_extra (@{$self->reviewers_extra_raw}) {
      if ($reviewer_extra->{reviewerPHID} eq $reviewer_phid) {
        if ($reviewer_extra->{diffPHID}) {
          if ( $reviewer_data->{status} eq 'accepted'
            && $reviewer_extra->{diffPHID} ne $self->diff_phid)
          {
            $reviewer_data->{status} = 'accepted-prior';
          }
        }
      }
    }
    push @reviewers, $reviewer_data;
  }

  return \@reviewers;
}

sub _build_subscribers {
  my ($self) = @_;

  return $self->{subscribers} if $self->{subscribers};
  return [] unless $self->subscribers_raw->{subscriberPHIDs};

  my @phids;
  foreach my $phid (@{$self->subscribers_raw->{subscriberPHIDs}}) {
    push @phids, $phid;
  }

  my $users = Bugzilla::Extension::PhabBugz::User->match({phids => \@phids});

  return $self->{subscribers} = $users;
}

sub _build_projects {
  my ($self) = @_;

  return $self->{projects} if $self->{projects};
  return [] unless $self->projects_raw->{projectPHIDs};

  my @projects;
  foreach my $phid (@{$self->projects_raw->{projectPHIDs}}) {
    push @projects,
      Bugzilla::Extension::PhabBugz::Project->new_from_query({phids => [$phid]});
  }

  return $self->{projects} = \@projects;
}

sub _build_repository {
  my ($self) = @_;
  return undef if !$self->repository_phid;
  return $self->{repository} if $self->{repository};

  # Cache repository objects per page request in case of
  # multiple revisions having the same repository
  my $cache = Bugzilla->request_cache;
  return $cache->{phab_repo_cache}->{$self->repository_phid}
    if exists $cache->{phab_repo_cache}->{$self->repository_phid};

  my $repository
    = Bugzilla::Extension::PhabBugz::Repository->new_from_query({
    phids => [$self->repository_phid]
    });
  if ($repository) {
    $cache->{phab_repo_cache}->{$self->repository_phid} = $repository;
    return $self->{repository} = $repository;
  }
  return undef;
}

sub _build_stack_graph {
  my ($self) = @_;

  my @phids = keys %{$self->stack_graph_raw};
  my @edges = ();

  foreach my $node (@phids) {
    my $predecessors = $self->stack_graph_raw->{$node};
    foreach my $predecessor (@{$predecessors}) {
      push @edges, [$node, $predecessor];
    }
  }

  return {phids => \@phids, edges => \@edges};
}

sub _build_comments {
  my ($self) = @_;

  return $self->{comments} if $self->{comments};

  my $result       = request('transaction.search', {objectIdentifier => $self->phid});
  my $transactions = [];
  if (exists $result->{result}{data} && @{$result->{result}{data}}) {
    $transactions = $result->{result}{data};
  }

  my @comments;
  foreach my $transaction (@{$transactions}) {
    next if !$transaction->{type} || $transaction->{type} ne 'comment';
    foreach my $comment (@{$transaction->{comments}}) {
      push @comments, Bugzilla::Extension::PhabBugz::Comment->new($comment);
    }
  }

  return $self->{comments} = \@comments;
}

#########################
#       Mutators        #
#########################

sub add_comment {
  my ($self, $comment) = @_;
  $comment = trim($comment);
  $self->{added_comments} ||= [];
  push @{$self->{added_comments}}, $comment;
}

sub add_reviewer {
  my ($self, $reviewer) = @_;
  $self->{add_reviewers} ||= [];
  my $reviewer_phid = blessed $reviewer ? $reviewer->phid : $reviewer;
  push @{$self->{add_reviewers}}, $reviewer_phid;
}

sub remove_reviewer {
  my ($self, $reviewer) = @_;
  $self->{remove_reviewers} ||= [];
  my $reviewer_phid = blessed $reviewer ? $reviewer->phid : $reviewer;
  push @{$self->{remove_reviewers}}, $reviewer_phid;
}

sub set_reviewers {
  my ($self, $reviewers) = @_;
  $self->{set_reviewers} = [map { $_->phid } @$reviewers];
}

sub add_subscriber {
  my ($self, $subscriber) = @_;
  $self->{add_subscribers} ||= [];
  my $subscriber_phid = blessed $subscriber ? $subscriber->phid : $subscriber;
  push @{$self->{add_subscribers}}, $subscriber_phid;
}

sub remove_subscriber {
  my ($self, $subscriber) = @_;
  $self->{remove_subscribers} ||= [];
  my $subscriber_phid = blessed $subscriber ? $subscriber->phid : $subscriber;
  push @{$self->{remove_subscribers}}, $subscriber_phid;
}

sub set_subscribers {
  my ($self, $subscribers) = @_;

  # Leave the subscribers alone if they already match. Conduit returns at
  # most 10 subscriberPHIDs, so only trust the list when it is complete.
  my $current
    = $self->subscribers_raw && $self->subscribers_raw->{subscriberPHIDs};
  if ($current && @$current == ($self->subscriber_count // 0)) {
    my %current = map { $_ => 1 } @$current;
    my %wanted  = map { $_ => 1 } @$subscribers;
    if (keys %current == keys %wanted && !grep { !$current{$_} } keys %wanted) {
      delete $self->{set_subscribers};
      return;
    }
  }

  $self->{set_subscribers} = $subscribers;
}

sub set_policy {
  my ($self, $name, $policy) = @_;
  $self->{set_policy} ||= {};
  $self->{set_policy}->{$name} = $policy;
}

sub set_status {
  my ($self, $status) = @_;
  $self->{set_status} = $status;
}

sub add_project {
  my ($self, $project) = @_;
  $self->{add_projects} ||= [];
  my $project_phid = blessed $project ? $project->phid : $project;
  return undef unless $project_phid;
  push @{$self->{add_projects}}, $project_phid;
}

sub remove_project {
  my ($self, $project) = @_;
  $self->{remove_projects} ||= [];
  my $project_phid = blessed $project ? $project->phid : $project;
  return undef unless $project_phid;
  push @{$self->{remove_projects}}, $project_phid;
}

sub make_private {
  my ($self, $project_names) = @_;

  my @set_projects;
  foreach my $name (@$project_names) {
    my $set_project = $self->{"_project_${name}"} ||=
      Bugzilla::Extension::PhabBugz::Project->new_from_query({name => $name});
    push @set_projects, $set_project;
  }

  my $new_policy = Bugzilla::Extension::PhabBugz::Policy->create(\@set_projects);
  $self->set_policy('view', $new_policy->phid);
  $self->set_policy('edit', $new_policy->phid);

  $self->{view_policy} = $new_policy->phid;

  return $self;
}

sub make_public {
  my ($self) = @_;

  my $editbugs = $self->{'_project_bmo-editbugs-team'} ||=
    Bugzilla::Extension::PhabBugz::Project->new_from_query({
    name => 'bmo-editbugs-team'
    });

  $self->set_policy('view', 'public');
  $self->set_policy('edit', ($editbugs ? $editbugs->phid : 'users'));

  $self->{view_policy} = 'public';

  my @current_group_projects
    = grep { $_->name =~ /^(bmo-.*|secure-revision)$/ } @{$self->projects};
  foreach my $project (@current_group_projects) {
    $self->remove_project($project->phid);
  }

  return $self;
}

sub is_private {
  my ($self) = @_;
  return $self->{view_policy} eq 'public' ? 0 : 1;
}

sub set_private_project_tags {
  my ($self, $project_names) = @_;

  my $secure_revision_project = $self->{'_project_secure-revision'} ||=
    Bugzilla::Extension::PhabBugz::Project->new_from_query({
    name => 'secure-revision'
    });

  my @set_projects;
  foreach my $name (@$project_names) {
    my $set_project = $self->{"_project_${name}"} ||=
      Bugzilla::Extension::PhabBugz::Project->new_from_query({name => $name});
    push @set_projects, $set_project;
  }

  foreach my $project ($secure_revision_project, @set_projects) {
    $self->add_project($project->phid);
  }
}

1;
