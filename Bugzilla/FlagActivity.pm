# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::FlagActivity;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Error;
use Bugzilla::Util qw(trim datetime_from);
use List::MoreUtils qw(none);

use base qw( Bugzilla::Object );

use constant DB_TABLE      => 'flag_activity';
use constant LIST_ORDER    => 'id';
use constant AUDIT_CREATES => 0;
use constant AUDIT_UPDATES => 0;
use constant AUDIT_REMOVES => 0;

use constant DB_COLUMNS => qw(
  id
  flag_when
  type_id
  flag_id
  setter_id
  who
  requestee_id
  bug_id
  attachment_id
  status
);

sub _check_param_required {
  my ($param) = @_;

  return sub {
    my ($invocant, $value) = @_;
    $value = trim($value) or ThrowCodeError('param_required', {param => $param});
    return $value;
  },;
}

sub _check_date {
  my ($invocant, $date) = @_;

  $date = trim($date);
  datetime_from($date)
    or ThrowUserError('illegal_date',
    {date => $date, format => 'YYYY-MM-DD HH24:MI:SS'});
  return $date;
}

sub _check_status {
  my ($self, $status) = @_;

  if (none { $status eq $_ } qw( X + - ? )) {
    ThrowUserError('flag_status_invalid', {id => $self->id, status => $status});
  }
  return $status;
}

use constant VALIDATORS => {
  flag_when => \&_check_date,
  type_id   => _check_param_required('type_id'),
  flag_id   => _check_param_required('flag_id'),
  setter_id => _check_param_required('setter_id'),
  who       => _check_param_required('who'),
  bug_id    => _check_param_required('bug_id'),
  status    => \&_check_status,
};

sub flag_when     { return $_[0]->{flag_when} }
sub type_id       { return $_[0]->{type_id} }
sub flag_id       { return $_[0]->{flag_id} }
sub setter_id     { return $_[0]->{setter_id} }
sub who           { return $_[0]->{who} }
sub bug_id        { return $_[0]->{bug_id} }
sub requestee_id  { return $_[0]->{requestee_id} }
sub attachment_id { return $_[0]->{attachment_id} }
sub status        { return $_[0]->{status} }

# SQL condition on flag_activity row $alias: true when it is newer than the
# bug's last flag change in bugs_activity. Older flag changes are read from
# bugs_activity, which has them all; flag_activity has only some of them,
# written to both tables, which must not be listed twice.
sub newer_than_bugs_activity_sql {
  my ($class, $alias) = @_;
  return "$alias.flag_when > COALESCE(
            (SELECT MAX(ba.bug_when) FROM bugs_activity ba
              WHERE ba.bug_id = $alias.bug_id
                    AND ba.fieldid = (SELECT id FROM fielddefs
                                       WHERE name = 'flagtypes.name')),
            '1970-01-01')";
}

# A flag created and updated in one request has several rows with the same
# flag_when and who. History shows the request's net change, like
# bugs_activity did: only its last row, compared with the flag's last row
# before the request. Rows are picked by id, which orders same-second rows.

# SQL condition on flag_activity row $alias: true for the request's last row.
sub last_of_request_sql {
  my ($class, $alias) = @_;
  return "NOT EXISTS (
            SELECT 1 FROM flag_activity next_fa
             WHERE next_fa.flag_id = $alias.flag_id
                   AND next_fa.flag_when = $alias.flag_when
                   AND next_fa.who = $alias.who
                   AND next_fa.id > $alias.id)";
}

# SQL subquery: the id of the flag's last row before $alias's request.
sub previous_id_sql {
  my ($class, $alias) = @_;
  return "(SELECT MAX(prev_fa.id) FROM flag_activity prev_fa
            WHERE prev_fa.flag_id = $alias.flag_id
                  AND prev_fa.id < $alias.id
                  AND NOT (prev_fa.flag_when = $alias.flag_when
                           AND prev_fa.who = $alias.who))";
}

sub type {
  my ($self) = @_;
  return $self->{type}
    //= Bugzilla::FlagType->new({id => $self->type_id, cache => 1});
}

sub setter {
  my ($self) = @_;
  return $self->{setter}
    //= Bugzilla::User->new({id => $self->setter_id, cache => 1});
}

sub requestee {
  my ($self) = @_;
  return undef unless defined $self->requestee_id;
  return $self->{requestee}
    //= Bugzilla::User->new({id => $self->requestee_id, cache => 1});
}

sub bug {
  my ($self) = @_;
  return $self->{bug} //= Bugzilla::Bug->new({id => $self->bug_id, cache => 1});
}

sub attachment {
  my ($self) = @_;
  return $self->{attachment}
    //= Bugzilla::Attachment->new({id => $self->attachment_id, cache => 1});
}

1;
