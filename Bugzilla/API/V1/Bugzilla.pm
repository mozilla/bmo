# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Bugzilla;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use DateTime;
use Try::Tiny;

use Bugzilla::Constants;
use Bugzilla::Logging;
use Bugzilla::Util qw(datetime_from);

sub setup_routes {
  my ($class, $r) = @_;

  $r->get('/version')->to('V1::Bugzilla#version');
  $r->get('/extensions')->to('V1::Bugzilla#extensions');
  $r->get('/timezone')->to('V1::Bugzilla#timezone');
  $r->get('/time')->to('V1::Bugzilla#time');
  $r->get('/jobqueue_status')->to('V1::Bugzilla#jobqueue_status');

  foreach my $path (qw(/version /extensions /timezone /time /jobqueue_status)) {
    $r->options($path)->to('V1::Bugzilla#options');
  }
}

sub options {
  my ($self) = @_;

  $self->res->headers->header('Allow'                        => 'GET');
  $self->res->headers->header('Access-Control-Allow-Methods' => 'GET');

  return $self->rendered(200);
}

sub version {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  return $self->render(json => {version => BUGZILLA_VERSION});
}

sub extensions {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my %extensions;
  foreach my $extension (@{Bugzilla->extensions}) {
    $extensions{$extension->NAME} = {version => $extension->VERSION || 0};
  }

  return $self->render(json => {extensions => \%extensions});
}

sub timezone {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  # All Webservices return times in UTC; Use UTC here for backwards compat.
  return $self->render(json => {timezone => '+0000'});
}

sub time {
  my ($self) = @_;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  # All Webservices return times in UTC; Use UTC here for backwards compat.
  my $dbh     = Bugzilla->dbh;
  my $db_time = $dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');
  $db_time = datetime_from($db_time, 'UTC')->iso8601();
  my $now_utc = DateTime->now()->iso8601();

  return $self->render(
    json => {
      db_time       => $db_time,
      web_time      => $now_utc,
      web_time_utc  => $now_utc,
      tz_name       => 'UTC',
      tz_offset     => '+0000',
      tz_short_name => 'UTC',
    }
  );
}

sub jobqueue_status {
  my ($self) = @_;

  my $user = $self->bugzilla->login;
  $user->id || return $self->user_error('login_required');

  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  my $dbh   = Bugzilla->dbh;
  my $query = q{
        SELECT
            COUNT(*) AS total,
            COALESCE(
                (SELECT COUNT(*)
                    FROM ts_error
                    WHERE ts_error.jobid = j.jobid
                )
            , 0) AS errors
        FROM ts_job j
            INNER JOIN ts_funcmap f
                ON f.funcid = j.funcid
        GROUP BY errors
    };

  my $status;
  try {
    $status = $dbh->selectrow_hashref($query);
  }
  catch {
    ERROR($_);
    return $self->code_error('jobqueue_status_error');
  };

  return $self->render(
    json => {
      errors => 0 + ($status->{errors} // 0),
      total  => 0 + ($status->{total}  // 0),
    }
  );
}

1;

__END__

=head1 NAME

Bugzilla::API::V1::Bugzilla - Global functions for the webservice interface.

=head1 DESCRIPTION

This provides functions that tell you about Bugzilla in general.
