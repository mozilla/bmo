# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Job::BugMailSend;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::User;
use parent qw(Bugzilla::Job::Mailer);

# Runs BugMail::Send for a list of bugs, for callers that touch too many
# bugs to do it inside the web request (e.g. a flag type inclusion/exclusion
# edit clearing flags across many bugs). A retry after a partial failure
# doesn't re-mail bugs already done: Send advances lastdiffed, so their
# window is empty the second time.
sub process_job {
  my ($class, $arg) = @_;
  my $changer = Bugzilla::User->new($arg->{changer_id});
  Bugzilla->set_user($changer);

  # new_from_list skips bugs deleted since the job was queued.
  Bugzilla::BugMail::Send($_->id, {changer => $changer})
    foreach @{Bugzilla::Bug->new_from_list($arg->{bug_ids})};
}

1;
