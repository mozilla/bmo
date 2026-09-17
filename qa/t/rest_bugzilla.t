# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use 5.10.1;
use strict;
use warnings;
use lib qw(lib ../../lib ../../local/lib/perl5);

use Bugzilla;
use Bugzilla::Constants;
use QA::Util qw(get_config);

use Test::Mojo;
use Test::More;

my $config  = get_config();
my $api_key = $config->{admin_user_api_key};
my $url     = Bugzilla->localconfig->urlbase;

my $t = Test::Mojo->new();

# Allow 1 redirect max
$t->ua->max_redirects(1);

# Check for version returned
$t->get_ok($url . 'rest/version')->status_is(200)->json_has('/version');

# Check for proper CORS headers
my $headers = $t->tx->res->headers;
ok($headers->header('Access-Control-Allow-Origin') eq '*');
ok($headers->header('Access-Control-Allow-Headers') =~ /x-bugzilla-api-key/);

# Make sure list of enabled extensions is returned
$t->get_ok($url . 'rest/extensions')->status_is(200)->json_has('/extensions');
my $extensions = $t->tx->res->json->{extensions};
my @ext_names  = sort keys %{$extensions};

# There is always at least the QA extension enabled.
ok(scalar @ext_names,
  scalar @ext_names . ' extension(s) found: ' . join ', ', @ext_names);
ok($extensions->{QA},
  'The QA extension is enabled, with version ' . $extensions->{QA}->{version});

# Check that the server timezone is returned
$t->get_ok($url . 'rest/timezone')->status_is(200)->json_has('/timezone');

# Check that the server times are returned
$t->get_ok($url . 'rest/time')->status_is(200)->json_has('/db_time')
  ->json_has('/web_time');

# Make sure there are no jobqueue errors
$t->get_ok($url . 'rest/jobqueue_status' => {'X-Bugzilla-API-Key' => $api_key})
  ->status_is(200)->json_is('/errors' => 0);

# Check the configuration data for this Bugzilla instance
$t->get_ok($url . 'rest/configuration')->status_is(200)
  ->json_is('/version' => BUGZILLA_VERSION)->json_has('/product');

done_testing();
