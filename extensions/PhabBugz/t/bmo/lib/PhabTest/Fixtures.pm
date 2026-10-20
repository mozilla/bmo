# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Builders for Conduit response objects. The shapes follow the Conduit API
# documentation (`/conduit/method/<name>/` on a Phabricator install) and the
# example payloads documented in the PhabBugz model modules. Every builder
# returns a fully populated object, because the Moo models type check each
# field and reject undefined values for most of them.

package PhabTest::Fixtures;

use 5.10.1;
use strict;
use warnings;

use base qw(Exporter);
our @EXPORT_OK = qw(
  edge_obj
  edit_result
  feed_story
  next_phid
  phid_for_bmo_user
  policy_obj
  project_obj
  repository_obj
  revision_obj
  search_result
  transaction_obj
  user_obj
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use Mojo::JSON qw(false true);

# Prefix generated PHIDs and ids with a per-run tag. Some PHIDs end up in
# BMO tables (phab_reviewer_rotation, phab_uplift_form_state), so they must
# not collide with rows left behind by earlier runs against the same DB.
my $RUN_TAG = lc sprintf('%x%x', time, $$);
my $COUNTER = 0;

# Revision ids also become BMO attachment filenames (phabricator-D<id>-url.txt)
# and Feed.pm matches attachments on other bugs by that filename, so they get
# their own counter seeded from the time and pid (1000 revisions per process).
my $NEXT_REVISION_ID = (time * 100_000 + $$ % 100_000) * 1_000;

sub next_phid {
  my ($type) = @_;
  return sprintf('PHID-%s-pt%s%06d', $type, $RUN_TAG, ++$COUNTER);
}

# A Phabricator user linked to a BMO account always gets the same PHID. The
# BMO id -> PHID mapping is cached in memcached by
# PhabBugz::User::get_phab_bugzilla_ids, so a stable PHID keeps that cache
# valid across test files and runs.
sub phid_for_bmo_user {
  my ($bmo_id) = @_;
  return sprintf('PHID-USER-bmo%017d', $bmo_id);
}

sub search_result {
  my ($data, %cursor) = @_;
  return {
    data   => $data,
    maps   => {},
    query  => {queryKey => undef},
    cursor => {
      limit  => $cursor{limit} // 100,
      after  => $cursor{after},
      before => $cursor{before},
      order  => $cursor{order},
    },
  };
}

# user.search item
sub user_obj {
  my (%args) = @_;
  my $username = $args{username} // 'phabtest-user-' . ++$COUNTER;
  return {
    id     => $args{id} // ++$COUNTER,
    type   => 'USER',
    phid   => $args{phid} // next_phid('USER'),
    fields => {
      username     => $username,
      realName     => $args{realname} // "Phab Test $username",
      roles        => $args{roles}    // [qw(verified approved activated)],
      dateCreated  => $args{created}  // 1_512_573_120,
      dateModified => $args{modified} // 1_512_574_523,
      policy       => {view => 'public', edit => 'no-one'},
    },
    attachments => {
      'external-accounts' => {
        'external-accounts' =>
          (defined $args{bmo_id} ? [{id => "$args{bmo_id}", type => 'bmo'}] : []),
      },
    },
  };
}

# project.search item (with the `members` attachment)
sub project_obj {
  my (%args) = @_;
  my $name = $args{name} // 'phabtest-project-' . ++$COUNTER;
  return {
    id     => $args{id} // ++$COUNTER,
    type   => 'PROJ',
    phid   => $args{phid} // next_phid('PROJ'),
    fields => {
      name         => $name,
      slug         => $name,
      milestone    => undef,
      depth        => 0,
      parent       => undef,
      icon         => {key => 'group', name => 'Group', icon => 'fa-users'},
      color        => {key => 'red',   name => 'Red'},
      dateCreated  => 1_500_403_964,
      dateModified => 1_505_248_862,
      description  => $args{description} // "Description for $name",
      policy       => {
        view => $args{view_policy} // 'public',
        edit => $args{edit_policy} // 'admin',
        join => $args{join_policy} // 'admin',
      },
    },
    attachments =>
      {members => {members => [map { {phid => $_} } @{$args{members} // []}]}},
  };
}

# differential.revision.search item (projects, reviewers, subscribers and,
# optionally, reviewers-extra attachments)
sub revision_obj {
  my (%args) = @_;
  my $id     = $args{id}     // ++$NEXT_REVISION_ID;
  my $phid   = $args{phid}   // next_phid('DREV');
  my $status = $args{status} // 'needs-review';

  my $revision = {
    id     => $id,
    type   => 'DREV',
    phid   => $phid,
    fields => {
      title          => $args{title}   // "Revision D$id",
      summary        => $args{summary} // "Summary for D$id",
      authorPHID     => $args{author_phid},
      diffPHID       => $args{diff_phid} // 'PHID-DIFF-current',
      repositoryPHID => $args{repository_phid},
      status         => {value => $status, name => $status, closed => false},
      isDraft        => ($args{is_draft}      ? true : false),
      holdAsDraft    => ($args{hold_as_draft} ? true : false),
      dateCreated    => 1_507_666_113,
      dateModified   => 1_508_514_027,
      policy         => {
        view => $args{view_policy} // 'public',
        edit => $args{edit_policy} // 'users',
      },
      'bugzilla.bug-id' => $args{bug_id},    # Conduit sends null when unset
      'uplift.request'  => $args{uplift_request} // [],
      stackGraph        => $args{stack_graph}    // {$phid => []},
    },
    attachments => {
      reviewers => {
        reviewers => [
          map {
            +{
              reviewerPHID => $_->{phid},
              status       => $_->{status} // 'added',
              isBlocking   => ($_->{blocking} ? true : false),
              actorPHID    => $_->{actor},
            }
          } @{$args{reviewers} // []}
        ],
      },
      subscribers => {
        subscriberPHIDs    => $args{subscribers} // [],
        subscriberCount    => scalar @{$args{subscribers} // []},
        viewerIsSubscribed => true,
      },
      projects => {projectPHIDs => $args{projects} // []},
    },
  };

  if ($args{reviewers_extra}) {
    $revision->{attachments}{'reviewers-extra'}{'reviewers-extra'} = [
      map {
        +{
          reviewerPHID => $_->{phid},
          voidedPHID   => $_->{voided},
          diffPHID     => $_->{diff},
        }
      } @{$args{reviewers_extra}}
    ];
  }

  return $revision;
}

# diffusion.repository.search item (with the `projects` attachment)
sub repository_obj {
  my (%args) = @_;
  my $short_name = $args{short_name} // 'phabtest-repo-' . ++$COUNTER;
  return {
    id     => $args{id} // ++$COUNTER,
    type   => 'REPO',
    phid   => $args{phid} // next_phid('REPO'),
    fields => {
      name          => $args{name} // $short_name,
      vcs           => 'git',
      callsign      => $args{callsign} // uc $short_name,
      shortName     => $short_name,
      status        => 'active',
      isImporting   => false,
      defaultBranch => 'main',
      description   => {raw => "Repository $short_name"},
      dateCreated   => 1_507_666_113,
      dateModified  => 1_508_514_027,
      policy => {view => 'public', edit => 'admin', 'diffusion.push' => 'no-one'},
    },
    attachments => {projects => {projectPHIDs => $args{projects} // []}},
  };
}

# policy.query item
sub policy_obj {
  my (%args) = @_;
  return {
    phid      => $args{phid} // next_phid('PLCY'),
    type      => 'custom',
    name      => 'Custom Policy',
    shortName => 'Custom Policy',
    fullName  => 'Custom Policy',
    href      => undef,
    workflow  => undef,
    icon      => 'fa-certificate',
    default   => $args{default} // 'deny',
    rules     => $args{rules}   // [],
  };
}

# feed.query_id item
sub feed_story {
  my (%args) = @_;
  my $id = $args{id} // ++$COUNTER;
  return {
    id               => $id,
    phid             => next_phid('STRY'),
    chronologicalKey => "6${id}000000",
    authorPHID       => $args{author_phid},
    objectPHID       => $args{object_phid},
    epoch            => 1_507_666_113 + $id,
    text             => $args{text} // "someone updated D$id.",
  };
}

# transaction.search item. Pass `comments => [text, ...]` for a comment
# transaction.
sub transaction_obj {
  my (%args) = @_;
  my $author = $args{author_phid} // next_phid('USER');
  return {
    id           => ++$COUNTER,
    phid         => next_phid('XACT'),
    type         => (exists $args{type} ? $args{type} : 'comment'),
    authorPHID   => $author,
    objectPHID   => $args{object_phid},
    dateCreated  => 1_507_666_113,
    dateModified => 1_507_666_113,
    groupID      => 'phabtestgroup',
    comments     => [
      map {
        +{
          id           => ++$COUNTER,
          phid         => next_phid('XCMT'),
          version      => 1,
          authorPHID   => $author,
          dateCreated  => 1_507_666_113,
          dateModified => 1_507_666_113,
          removed      => false,
          content      => {raw => $_},
        }
      } @{$args{comments} // []}
    ],
    fields => {},
  };
}

# edge.search item
sub edge_obj {
  my ($source, $destination, $type) = @_;
  return {
    sourcePHID      => $source,
    edgeType        => $type // 'revision.child',
    destinationPHID => $destination,
  };
}

# Result of the *.edit methods (project.edit, differential.revision.edit,
# user.edit)
sub edit_result {
  my ($phid, $id) = @_;
  return {
    object       => {id => $id // ++$COUNTER, phid => $phid},
    transactions => [{phid => next_phid('XACT')}],
  };
}

1;
