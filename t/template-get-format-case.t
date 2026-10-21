#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# Bug 2081090 - get_format must treat ctype case-insensitively so that a
# value like "CSV" cannot bypass the contenttypes lookup or callers'
# checks against $format->{extension}.

use 5.10.1;
use strict;
use warnings;

use lib qw(. lib local/lib/perl5);
use Test::More;

BEGIN {
  use_ok('Template');
  use_ok('Bugzilla::Template');
}

# get_format only needs $self->context->template, so a plain Template
# Toolkit object over the real template directory is enough. On a
# case-sensitive filesystem this also proves the lowercase template name
# is the one being resolved.
my $template = bless Template->new({INCLUDE_PATH => 'template/en/default'}),
  'Bugzilla::Template';

foreach my $ctype (qw(csv CSV Csv cSv)) {
  my $format = $template->get_format('list/list', '', $ctype);
  is($format->{extension}, 'csv',      "ctype=$ctype: extension is csv");
  is($format->{ctype},     'text/csv', "ctype=$ctype: content type is text/csv");
  is($format->{template}, 'list/list.csv.tmpl',
    "ctype=$ctype: template name is lowercase");
}

my $html = $template->get_format('list/list', '', 'HTML');
is($html->{extension}, 'html',      'ctype=HTML: extension is html');
is($html->{ctype},     'text/html', 'ctype=HTML: content type is text/html');

my $default = $template->get_format('list/list', '', undef);
is($default->{extension}, 'html', 'missing ctype defaults to html');

my $unknown = $template->get_format('global/variables', '', 'NONE');
is($unknown->{extension}, 'none', 'unknown ctype is lowercased');
is($unknown->{ctype}, 'application/octet-stream',
  'unknown ctype falls back to application/octet-stream');

done_testing();
