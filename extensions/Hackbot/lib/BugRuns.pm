# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot::BugRuns;

# The Hackbot runs for one bug, as shown in the bug page table.
#
# Two layers:
#   - for_bug() keeps a per-bug memcached copy of the run list, revalidated
#     with the API's ETag once the short freshness window has passed.
#   - The cached copy holds only the trimmed upstream fields (_trim). Display
#     rows are built on every request (_summarize), so nicknames and the origin
#     rules are never stale and changing them needs no cache-key bump.
#
# The cache is shared by every user who can see the bug. That is safe because
# the caller checks bug visibility first and the cached data holds nothing
# specific to the viewer.

use 5.10.1;
use strict;
use warnings;

use Bugzilla;
use Bugzilla::Logging;
use Bugzilla::User;
use Bugzilla::Extension::Hackbot::Client;
use Bugzilla::Extension::Hackbot::Constants;

use constant CACHE_KEY_PREFIX => 'hackbot_runs.v1.';

# Whether the runs table is switched on. Checked by the bug page hook and the
# API alike, so both honour the same kill switch.
sub enabled {
  return Bugzilla->params->{hackbot_runs_enabled};
}

# Returns {ok => 1, runs => [rows]} or {ok => 0} when the API is unreachable.
# Pass `client` to substitute the HTTP client (tests).
sub for_bug {
  my ($class, $bug_id, %args) = @_;

  my $key    = CACHE_KEY_PREFIX . $bug_id;
  my $cached = Bugzilla->memcached->get_data({key => $key});
  $cached = undef unless ref $cached eq 'HASH';

  my $entry;
  if ($cached && ($cached->{fresh_until} // 0) > time()) {
    $entry = $cached;
  }
  else {
    $entry = _refresh($key, $bug_id, $cached,
      $args{client} // Bugzilla::Extension::Hackbot::Client->new);
  }

  return {ok => 0} if $entry->{error};
  # Runs often share a requester, so look each email up only once.
  my %nicks;
  return {ok => 1, runs => [map { _summarize($_, \%nicks) } @{$entry->{runs}}]};
}

# Fetch from the API, conditionally when the stale copy has an ETag, and store
# the result. Returns the new cache entry.
sub _refresh {
  my ($key, $bug_id, $cached, $client) = @_;

  # Only a good list is worth revalidating; an error entry is refetched.
  my $stale = ($cached && !$cached->{error}) ? $cached : undef;

  my $response = $client->bug_runs($bug_id, $stale && $stale->{etag});

  unless ($response->{ok}) {
    _warn_failure($bug_id, $response);
    my $entry = {error => 1, fresh_until => time() + HACKBOT_ERROR_CACHE_SECONDS};
    _store($key, $entry, HACKBOT_ERROR_CACHE_SECONDS);
    return $entry;
  }

  # A 304 is only possible when we sent an ETag, i.e. when $stale exists.
  my $runs
    = $response->{not_modified}
    ? $stale->{runs}
    : [grep {defined} map { _trim($_, $bug_id) } @{$response->{runs}}];

  my $entry = {
    runs        => $runs,
    etag        => $response->{etag},
    fresh_until => time() + HACKBOT_CACHE_SECONDS,
  };
  _store($key, $entry, HACKBOT_REVALIDATE_SECONDS);
  return $entry;
}

sub _store {
  my ($key, $entry, $ttl) = @_;
  Bugzilla->memcached->set_data({key => $key, value => $entry, expires_in => $ttl
  });
}

# Reduce an API RunDoc to the fields the table needs, or undef to drop it.
sub _trim {
  my ($run, $bug_id) = @_;

  return undef unless ref $run eq 'HASH';
  return undef unless ($run->{run_id} // '') =~ HACKBOT_RUN_ID_REGEX;

  # Only keep runs that are for this bug. The API filters by bug_id, but an
  # API that ignored the filter (an older deploy treats it as an unknown query
  # parameter) would return every run, including runs on bugs this user may
  # not be allowed to see.
  my $inputs = ref $run->{inputs} eq 'HASH' ? $run->{inputs} : {};
  return undef unless ($inputs->{bug_id} // '') =~ /^\d+$/;
  return undef unless $inputs->{bug_id} == $bug_id;

  my $created_at = $run->{created_at} // '';
  $created_at = undef
    unless $created_at =~ /^\d{4}-\d\d-\d\dT[\d:.]+(?:Z|[+-]\d\d:?\d\d)?$/;

  return {
    run_id        => lc $run->{run_id},
    agent         => _string($run->{agent}),
    status        => _string($run->{status}),
    created_at    => $created_at,
    requested_by  => _string($run->{requested_by}),
    requested_via => _string($run->{requested_via}),
    needinfo      => $inputs->{bugzilla_needinfo_flag_id} ? 1 : 0,
  };
}

# Build the display row for one trimmed run.
sub _summarize {
  my ($run, $nicks) = @_;

  my $origin
    = $run->{needinfo}                                          ? 'needinfo'
    : ($run->{requested_via} // '') =~ HACKBOT_UI_ACCOUNT_REGEX ? 'ui'
    :                                                             'other';

  return {
    run_id => $run->{run_id},
    url    => Bugzilla->params->{hackbot_ui_url} . 'runs/' . $run->{run_id},
    agent  => $run->{agent},
    status => HACKBOT_RUN_STATUSES->{$run->{status} // ''}
    ? $run->{status}
    : 'unknown',
    created_at => $run->{created_at},
    origin     => $origin,
    requester  => _requester_nick($run->{requested_by}, $nicks),
  };
}

# The BMO nickname for the requester's email, or undef when the email isn't a
# BMO account. Only the nick is sent to the browser, never the email.
# $nicks memoizes lookups, including misses, which the object cache doesn't.
sub _requester_nick {
  my ($email, $nicks) = @_;
  return undef unless $email;
  return $nicks->{$email} if exists $nicks->{$email};
  my $user = Bugzilla::User->new({name => $email, cache => 1});
  return $nicks->{$email} = $user && $user->id ? $user->nick : undef;
}

sub _string {
  my ($value) = @_;
  return defined $value && !ref $value ? "$value" : undef;
}

sub _warn_failure {
  my ($bug_id, $response) = @_;
  my $status = $response->{status} // 0;
  if ($status == 401 || $status == 403) {
    WARN( "Hackbot: auth failure ($status) listing runs for bug $bug_id"
        . " - check hackbot_api_key");
  }
  else {
    WARN("Hackbot: failed to list runs for bug $bug_id: " . $response->{errmsg});
  }
}

1;
