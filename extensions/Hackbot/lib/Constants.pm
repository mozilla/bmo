# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::Hackbot::Constants;

use 5.10.1;
use strict;
use warnings;

use base 'Exporter';

our @EXPORT = qw(
  HACKBOT_GROUP
  HACKBOT_API_TIMEOUT
  HACKBOT_MAX_RUNS
  HACKBOT_CACHE_SECONDS
  HACKBOT_REVALIDATE_SECONDS
  HACKBOT_ERROR_CACHE_SECONDS
  HACKBOT_RUN_STATUSES
  HACKBOT_RUN_ID_REGEX
  HACKBOT_UI_ACCOUNT_REGEX
);

# Only members of this group see Hackbot runs, on the bug page or via the API.
use constant HACKBOT_GROUP => 'editbugs';

# Seconds to wait for the Hackbot API before giving up. The table is loaded
# asynchronously, so a slow API delays only the table, never the bug page.
use constant HACKBOT_API_TIMEOUT => 10;

# The most runs shown for one bug (sent as the API's `limit`; newest first).
use constant HACKBOT_MAX_RUNS => 50;

# Freshness window: how long a cached run list is served without contacting
# Hackbot. Kept short because a run moves pending -> running -> done within
# minutes, and the point of the table is to show that progress.
use constant HACKBOT_CACHE_SECONDS => 30;

# Hard memcached TTL. Much longer than the freshness window so the stored ETag
# outlives it and a stale entry can be revalidated with If-None-Match (a cheap
# 304) instead of a full fetch.
use constant HACKBOT_REVALIDATE_SECONDS => 86_400;

# Failed lookups are cached briefly so a Hackbot outage doesn't add an API
# call to every bug view, while still recovering quickly.
use constant HACKBOT_ERROR_CACHE_SECONDS => 60;

# The run states defined by the Hackbot API (RunStatus in hackbot-api).
use constant HACKBOT_RUN_STATUSES =>
  {map { $_ => 1 } qw(pending running succeeded failed timed_out)};

# Run ids are UUIDs. Anything else is dropped rather than put into a link.
use constant HACKBOT_RUN_ID_REGEX => qr{
  ^ [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4}
    - [[:xdigit:]]{4} - [[:xdigit:]]{12} $
}x;

# `requested_via` holds the service account that created the run. Runs
# started from the Hackbot UI come from its Cloud Run service account.
use constant HACKBOT_UI_ACCOUNT_REGEX => qr/^hackbot-ui-run@/;

1;
