# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::BMO::Data;

use 5.10.1;
use strict;
use warnings;

use base qw(Exporter);
use Tie::IxHash;

our @EXPORT = qw( $cf_visible_in_products
  %group_change_notification
  @always_fileable_groups
  %group_auto_cc
  %create_bug_formats
  @default_named_queries
  %autodetect_attach_urls
  @triage_keyword_products
  PRODUCT_CHANNELS
  $flag_pronoun_re );

use constant PRODUCT_CHANNELS => {
  'firefox' => {
    'nightly' => {label => 'Nightly', json_key => 'FIREFOX_NIGHTLY'},
    'beta'    => {label => 'Beta',    json_key => 'LATEST_FIREFOX_DEVEL_VERSION'},
    'release' => {label => 'Release', json_key => 'LATEST_FIREFOX_VERSION'},
    'esr'     => {label => 'ESR',     json_key => 'FIREFOX_ESR'},
  },
  'thunderbird' => {
    'nightly' => {label => 'Daily',   json_key => 'LATEST_THUNDERBIRD_NIGHTLY_VERSION'},
    'beta'    => {label => 'Beta',    json_key => 'LATEST_THUNDERBIRD_DEVEL_VERSION'},
    'release' => {label => 'Release', json_key => 'LATEST_THUNDERBIRD_VERSION'},
  },
};

our $flag_pronoun_re = do {
  # Get the Firefox channel list and build a regex pattern. Thunderbird doesn’t
  # have ESR now but it won't be practically a problem.
  my $channels_re = join('|', keys %{PRODUCT_CHANNELS->{'firefox'}});
  qr/^cf_(status|tracking)_(firefox|thunderbird)_($channels_re)$/;
};

sub phabricator_url_re {
  my $params = Bugzilla->params;
  return qr/(?!)/ unless $params->{phabricator_enabled};

  my $phab_uri = $params->{phabricator_base_uri};
  return qr/(?!)/ unless $phab_uri;

  return qr/^\Q${phab_uri}\ED\d+$/i;
}

# Creating an attachment whose contents is a URL matching one of these regexes
# will result in the user being redirected to that URL when viewing the
# attachment.
our %autodetect_attach_urls = (
  github_pr => {
    title        => 'GitHub Pull Request',
    regex        => qr#^https://github\.com/[^/]+/[^/]+/pull/\d+/?$#i,
    content_type => 'text/x-github-pull-request',
    can_review   => 1,
    can_user_set => 1,
  },
  phabricator => {
    title        => 'Phabricator',
    regex        => \&phabricator_url_re,
    content_type => 'text/x-phabricator-request',
    can_review   => 1,
    can_user_set => 0,
  },
  google_docs => {
    title => 'Google Doc',
    regex =>
      qr#^https://docs\.google\.com/(?:document|spreadsheets|presentation)/d/#i,
    content_type => 'text/x-google-doc',
    can_review   => 0,
    can_user_set => 1,
  },
);

# Which custom fields are visible in which products and components.
#
# By default, custom fields are visible in all products. However, if the name
# of the field matches any of these regexps, it is only visible if the
# product (and component if necessary) is a member of the attached hash. []
# for component means "all".
#
# IxHash keeps them in insertion order, and so we get regexp priorities right.
our $cf_visible_in_products;
tie(
  %$cf_visible_in_products,
  "Tie::IxHash",
  qr/^cf_colo_site$/ => {
    "mozilla.org" => [
      "Server Operations",
      "Server Operations: DCOps",
      "Server Operations: Projects",
      "Server Operations: RelEng",
      "Server Operations: Security",
    ],
    "Infrastructure & Operations" => ["RelOps", "RelOps: Puppet", "DCOps",],
  },
  qr/^cf_office$/ => {"mozilla.org" => ["Server Operations: Desktop Issues"],},
  qr/^cf_crash_signature$/ => {
    "Add-on SDK"                                    => [],
    "addons.mozilla.org"                            => [],
    "Android Background Services"                   => [],
    "Application Services"                          => [],
    "Calendar"                                      => [],
    "Camino Graveyard"                              => [],
    "Composer"                                      => [],
    "Core"                                          => [],
    "Core Graveyard"                                => [],
    "Data Platform and Tools"                       => [],
    "DevTools"                                      => [],
    "Directory"                                     => [],
    "External Software Affecting Firefox"           => [],
    "External Software Affecting Firefox Graveyard" => [],
    "Firefox"                                       => [],
    "Firefox Build System"                          => [],
    "Firefox for Android"                           => [],
    "Firefox for Android Graveyard"                 => [],
    "Firefox for Metro Graveyard"                   => [],
    "Firefox OS Graveyard"                          => [],
    "Focus"                                         => [],
    "GeckoView"                                     => [],
    "Infrastructure & Operations"                   => [],
    "Infrastructure & Operations Graveyard"         => [],
    "JSS"                                           => [],
    "MailNews Core"                                 => [],
    "Mozilla Labs"                                  => [],
    "Mozilla Localizations"                         => [],
    "mozilla.org"                                   => [],
    "Cloud Services"                                => [],
    "NSPR"                                          => [],
    "NSS"                                           => [],
    "Other Applications"                            => [],
    "Penelope"                                      => [],
    "Plugins"                                       => [],
    "Plugins Graveyard"                             => [],
    "Release Engineering"                           => [],
    "Remote Protocol"                               => [],
    "Rhino"                                         => [],
    "SeaMonkey"                                     => [],
    "Socorro"                                       => [],
    "Tamarin"                                       => [],
    "Taskcluster"                                   => [],
    "Tech Evangelism"                               => [],
    "Testing"                                       => [],
    "Thunderbird"                                   => [],
    "Toolkit"                                       => [],
    "Web Compatibility"                             => [],
    "WebExtensions"                                 => [],
  },
  qr/^cf_due_date$/ => {
    "bugzilla.mozilla.org"        => [],
    "Calendar"                    => [],
    "Community Building"          => [],
    "Data & BI Services Team"     => [],
    "Data Compliance"             => [],
    "Developer Engagement"        => [],
    "Firefox"                     => ["Security: Review Requests"],
    "Infrastructure & Operations" => [],
    "MailNews Core"               => [],
    "Marketing"                   => [],
    "mozilla.org"                 => ["Security Assurance: Review Request"],
    "Mozilla Metrics"             => [],
    "Mozilla PR"                  => [],
    "Mozilla Reps"                => [],
    "Thunderbird"                 => [],
  },
  qr/^cf_locale$/ =>
    {"Mozilla Localizations" => ['Other'], "www.mozilla.org" => [],},
  qr/^cf_mozilla_project$/ => {"Data & BI Services Team" => [],},
  qr/^cf_machine_state$/   => {"Release Engineering"     => ["Buildduty"],},
  qr/^cf_rank$/            => {
    "Core"                => [],
    "Firefox for Android" => [],
    "Firefox for iOS"     => [],
    "Firefox"             => [],
    "Focus"               => [],
    "GeckoView"           => [],
    "Hello (Loop)"        => [],
    "Cloud Services"      => [],
    "Tech Evangelism"     => [],
    "Toolkit"             => [],
  },
  qr/^cf_has_str$/ => {
    "Core Graveyard"                      => [],
    "Core"                                => [],
    "DevTools Graveyard"                  => [],
    "DevTools"                            => [],
    "External Software Affecting Firefox" => [],
    "Firefox Build System"                => [],
    "Firefox for Android Graveyard"       => [],
    "Firefox for Android"                 => [],
    "Firefox for iOS"                     => [],
    "Firefox Graveyard"                   => [],
    "Firefox"                             => [],
    "GeckoView"                           => [],
    "NSS"                                 => [],
    "Tech Evangelism Graveyard"           => [],
    "Tech Evangelism"                     => [],
    "Toolkit Graveyard"                   => [],
    "Toolkit"                             => [],
    "WebExtensions"                       => [],
  },
);

# Products that use the triage keyword.
our @triage_keyword_products = (
    'Conduit',
    'Core',
    'DevTools',
    'External Software Affecting Firefox',
    'Firefox Build System',
    'Firefox for Android',
    'Firefox for iOS',
    'Firefox',
    'GeckoView',
    'JSS',
    'NSPR',
    'NSS',
    'Remote Protocol',
    'Testing',
    'Toolkit',
    'WebExtensions',
);

# Who to CC on particular bugmails when certain groups are added or removed.
our %group_change_notification = (
  'addons-security'   => ['amo-editors@mozilla.org'],
  'bugzilla-security' => ['security@bugzilla.org'],
  'client-services-security' =>
    ['amo-admins@mozilla.org', 'web-security@mozilla.org'],
  'cloud-services-security'  => ['web-security@mozilla.org'],
  'core-security'            => ['security@mozilla.org'],
  'crypto-core-security'     => ['security@mozilla.org'],
  'dom-core-security'        => ['security@mozilla.org'],
  'firefox-core-security'    => ['security@mozilla.org'],
  'gfx-core-security'        => ['security@mozilla.org'],
  'javascript-core-security' => ['security@mozilla.org'],
  'layout-core-security'     => ['security@mozilla.org'],
  'mail-core-security'       => ['security@mozilla.org'],
  'media-core-security'      => ['security@mozilla.org'],
  'network-core-security'    => ['security@mozilla.org'],
  'core-security-release'    => ['security@mozilla.org'],
  'tamarin-security'         => ['tamarinsecurity@adobe.com'],
  'toolkit-core-security'    => ['security@mozilla.org'],
  'websites-security'        => ['web-security@mozilla.org'],
  'webtools-security'        => ['web-security@mozilla.org'],
);

# Groups in which you can always file a bug, regardless of product or user.
our @always_fileable_groups = qw(
  addons-security
  bugzilla-security
  client-services-security
  consulting
  core-security
  finance
  infra
  infrasec
  l20n-security
  marketing-private
  mozilla-confidential
  mozilla-employee-confidential
  mozilla-foundation-confidential
  mozilla-engagement
  mozilla-messaging-confidential
  partner-confidential
  payments-confidential
  tamarin-security
  websites-security
  webtools-security
);

# Automatically CC users to bugs filed into configured groups and products
our %group_auto_cc = (
  'partner-confidential' => {
    'Marketing' => ['jbalaco@mozilla.com'],
    # As the group is for generic partnership it's hard to find a specific person
    # who could fix bugs that are accidentally placed in this group. Setting to
    # glob for now who will update the bugs appropriately.
    '_default'  => ['glob@mozilla.com'],
  },
);

# Force create-bug template by product
# Users in 'include' group will be forced into using the form.
our %create_bug_formats = (
  'Data Compliance' => {'format' => 'data-compliance', 'include' => 'everyone',},
  'Legal'                 => {'format' => 'legal',      'include' => 'everyone',},
  'Toolkit'               => {'component' => 'Blocklist Policy Requests',
                              'format' => 'blocklist', 'include' => 'everyone',},
  'Internet Public Policy' => {'format' => 'ipp', 'include' => 'everyone',},
);

# List of named queries which will be added to new users' footer
our @default_named_queries = (
  {
    name => 'Bugs Filed Today',
    query =>
      'query_format=advanced&chfieldto=Now&chfield=[Bug creation]&chfieldfrom=-24h&order=bug_id',
  },
);

1;
