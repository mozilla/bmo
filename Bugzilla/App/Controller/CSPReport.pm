# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Controller::CSPReport;

use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Logging;
use Bugzilla::Util qw(remote_ip);
use Mojo::JSON qw(decode_json);
use Try::Tiny;

# Collector for Content-Security-Policy violation reports.
#
# This is a temporary aid for the CSP-enforcement rollout: while the legacy
# CGI pages remain in report-only mode, browsers POST a JSON report here for
# every violation. Aggregating them
# server-side lets us build an inventory of what would break under enforcement
# without relying on someone watching the DevTools console on every page.
#
# Only the report-uri wire format is handled: that is the only reporting
# directive DEFAULT_CSP emits. We deliberately do not parse the Reporting API
# ("report-to") batch format, since nothing sets a Reporting-Endpoints header,
# and accepting an array of reports would let a single request produce an
# unbounded number of log lines.
#
# Each report is written to the application log twice over: as MozLog "Fields"
# entries, so the inventory can be built with structured tooling (jq, the GCP
# logging console), and as a flat summary line tagged "CSP-VIOLATION" for
# grepping. Once all legacy pages are clean and CSP is enforced globally, both
# this controller and the report_uri directive in DEFAULT_CSP can be removed.

# Untrusted report values are written to a single log line, so cap their length
# to keep log volume bounded and strip control characters to defeat multi-line
# log injection.
use constant MAX_FIELD_LENGTH => 500;
use constant MAX_BODY_LENGTH  => 2000;

# The endpoint is unauthenticated and always 204s, so guard against being used
# to force repeated JSON parsing of large payloads. Genuine CSP reports are a
# few KiB at most; reject anything larger before we attempt to decode it. This
# is well under Mojo's default max_message_size (16 MiB), which still bounds how
# much we ever buffer.
use constant MAX_REPORT_SIZE => 64 * 1024;

# Used when the rate_limit_rules param carries no csp_report entry, which is the
# case until update_rate_limit_rules has run on an existing install. An absent
# rule must not mean "unlimited" for what is otherwise a log-flood vector.
use constant DEFAULT_RATE_LIMIT => [100, 60];

# The fields we lift out of a report, in the order the summary line lists them.
use constant REPORT_FIELDS =>
  qw( document directive blocked source line disposition );

sub setup_routes {
  my ($class, $r) = @_;
  $r->post('/csp_report')
    ->to('CSPReport#report', request_limit_format => 'empty');
}

sub report {
  my ($self) = @_;

  # Unauthenticated endpoint with no user-visible response, so a single client
  # can otherwise write log lines as fast as it can POST. Drop silently past
  # the per-IP rate: logging the fact that we are rate limiting would defeat
  # the purpose. This deliberately uses should_rate_limit rather than
  # Bugzilla->check_rate_limit, because the latter calls block_ip() and a busy
  # legitimate browser can produce a burst of genuine reports -- we want the
  # excess reports dropped, not the user locked out of BMO.
  my $limit = _rate_limit();
  if ($limit
    && Bugzilla->memcached->should_rate_limit('csp_report:' . remote_ip(), @$limit))
  {
    return $self->render(data => '', status => 204);
  }

  # Browsers send the report body as application/csp-report. Read the raw body
  # ourselves rather than relying on Mojo's form/JSON parsing, which keys off
  # Content-Type.
  my $body = $self->req->body // '';

  # Discard oversized bodies before spending CPU on JSON parsing. Browsers
  # ignore the response anyway, so just acknowledge receipt.
  if (length($body) > MAX_REPORT_SIZE) {
    WARN('CSP-VIOLATION oversized report discarded: ' . length($body) . ' bytes');
    return $self->render(data => '', status => 204);
  }

  try {
    my $data = decode_json($body);

    # report-uri wraps a single violation in a "csp-report" key. Fall back to
    # logging the (sanitised, truncated) payload if the shape is unexpected.
    if (ref $data eq 'HASH' && ref $data->{'csp-report'} eq 'HASH') {
      _log_violation(_normalize_report_uri($data->{'csp-report'}));
    }
    else {
      WARN('CSP-VIOLATION '
          . _encode_field(_clean(_redact_queries($body), MAX_BODY_LENGTH)));
    }
  }
  catch {
    WARN('CSP-VIOLATION unparseable report: '
        . _encode_field(_clean(_redact_queries($body), MAX_BODY_LENGTH)));
  };

  # Browsers ignore the response body; just acknowledge receipt.
  return $self->render(data => '', status => 204);
}

# Per-IP rate for accepting reports, as [count, seconds], or undef when rate
# limiting is switched off site-wide. Read from the rate_limit_rules param so
# the rate can be retuned from editparams.cgi rather than by deploying.
sub _rate_limit {
  my $params = Bugzilla->params;
  return undef if !$params->{rate_limit_active};

  my $rules = eval { decode_json($params->{rate_limit_rules} // '{}') } // {};
  my $limit = $rules->{csp_report};
  return (ref $limit eq 'ARRAY' && @$limit >= 2) ? $limit : DEFAULT_RATE_LIMIT;
}

# Log a single violation, structured and flat.
#
# The structured half is what makes the report-only soak workable: the fields
# land in MozLog's "Fields" object (see Log::Log4perl::Layout::Mozilla), so the
# inventory of what would break under enforcement can be aggregated with jq or
# the GCP logging console instead of by parsing a log line.
#
# The flat half is kept because only conf/log4perl-json.conf uses that layout.
# The development config (conf/log4perl-docker.conf) renders with PatternLayout,
# which drops Fields entirely, so the summary line is all a local developer --
# or anyone grepping -- would otherwise see.
sub _log_violation {
  my ($report) = @_;

  # MozLog Fields are JSON values, so these need no delimiter encoding: JSON
  # quoting already makes field forgery impossible. They only need the control
  # character strip and the length cap. Undefined values are skipped rather
  # than sent as "-", so a query for a missing field matches nothing instead of
  # matching a placeholder. The MDC context these live in is per-request --
  # Bugzilla::cleanup calls MDC->remove -- and this endpoint logs at most one
  # report per request, so nothing leaks onto unrelated log lines.
  my $fields = Bugzilla::Logging->fields;
  foreach my $key (REPORT_FIELDS) {
    next if !defined $report->{$key} || $report->{$key} eq '';
    $fields->{"csp_$key"} = _clean($report->{$key});
  }

  WARN(sprintf(
    'CSP-VIOLATION document=%s directive=%s blocked=%s source=%s:%s disposition=%s',
    map { _encode_field(_clean($_)) } @{$report}{(REPORT_FIELDS)}
  ));
}

# report-uri format: hyphenated keys inside "csp-report".
sub _normalize_report_uri {
  my ($report) = @_;
  return {
    document  => _strip_query($report->{'document-uri'}),
    directive => $report->{'violated-directive'} // $report->{'effective-directive'},
    blocked   => _strip_query($report->{'blocked-uri'}),
    source    => _strip_query($report->{'source-file'}),
    line      => $report->{'line-number'},

    # "report" or "enforce": whether the browser actually blocked the resource.
    # Once pages start moving to enforcing this is the difference between a
    # violation we still have time to fix and one that is already breaking.
    disposition => $report->{'disposition'},
  };
}

# Drop the query string and fragment from a reported URL before it reaches the
# log. CSP's "strip URL for use in reports" algorithm removes credentials and
# the fragment but keeps the query string, and BMO puts one-time secrets there:
# token.cgi?t=<token> is the password-reset and email-change confirmation link,
# and API keys can appear as api_key=. In report-only mode the browser reports
# *every* violation -- including ones caused by an extension injecting an
# inline script -- so those URLs would otherwise be logged verbatim. The path
# is all we need to identify the offending page.
sub _strip_query {
  my ($url) = @_;
  return $url if !defined $url;
  $url =~ s/[?#].*\z//s;
  return $url;
}

# Same concern as _strip_query, for the raw-payload fallback: we have no field
# structure to work with there, so redact anything that looks like a query
# string or fragment inside a JSON string value.
sub _redact_queries {
  my ($body) = @_;
  $body =~ s/([?#])[^"\\\s]*/$1<redacted>/g;
  return $body;
}

# Make an untrusted value safe to log: coerce undef/empty to "-", replace
# control characters (defeats multi-line log injection) and truncate to keep log
# volume bounded.
sub _clean {
  my ($value, $max) = @_;
  $max //= MAX_FIELD_LENGTH;
  return '-' if !defined $value || $value eq '';
  $value =~ s/[[:cntrl:]]/ /g;
  if (length($value) > $max) {
    $value = substr($value, 0, $max) . '...';
  }
  return $value;
}

# Percent-encode the delimiters of the flat summary line, which is a space
# delimited list of key=value pairs. This endpoint is reachable by a plain
# cross-site form POST, so without the encoding a value containing
# " directive=" would forge an extra field, and nothing downstream could tell a
# forged field from a browser-reported one -- and that inventory is what decides
# which scripts get added to CSP_ENFORCE_CGI. "%" is encoded first to keep the
# encoding reversible. Runs after _clean so truncation cannot split an escape.
sub _encode_field {
  my ($value) = @_;
  $value =~ s/%/%25/g;
  $value =~ s/ /%20/g;
  $value =~ s/=/%3D/g;
  return $value;
}

1;
