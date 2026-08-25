# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Keyword;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::Object);

use Bugzilla::Error;
use Bugzilla::Util;

###############################
####    Initialization     ####
###############################

use constant IS_CONFIG => 1;

use constant DB_COLUMNS => qw(
  keyworddefs.id
  keyworddefs.name
  keyworddefs.description
  keyworddefs.is_active
);

use constant DB_TABLE => 'keyworddefs';

use constant VALIDATORS => {
  name        => \&_check_name,
  description => \&_check_description,
  is_active   => \&_check_is_active,
};

use constant UPDATE_COLUMNS => qw(
  name
  description
  is_active
);

# Keyword families that classify security vulnerabilities. Bug counts for these
# keywords are hidden from users who cannot see security bugs (bug 2056990).
#
# Note that C<csectype> must be listed separately from C<csec>: the alternation
# is anchored on the trailing hyphen, so C<csec> only matches C<csec-*> and
# never C<csectype-*>.
use constant SECURITY_KEYWORD_REGEX => qr/^(?:sec|csec|csectype|wsec|opsec)-/;

###############################
####      Accessors      ######
###############################

sub description { return $_[0]->{'description'}; }

sub bug_count {
  my ($self) = @_;
  return $self->{'bug_count'} if defined $self->{'bug_count'};
  ($self->{'bug_count'})
    = Bugzilla->dbh->selectrow_array(
    'SELECT COUNT(*) FROM keywords WHERE keywordid = ?',
    undef, $self->id);
  return $self->{'bug_count'};
}

sub is_security_keyword {
  my ($self) = @_;
  return $self->name =~ SECURITY_KEYWORD_REGEX ? 1 : 0;
}

###############################
####       Mutators       #####
###############################

sub set_name        { $_[0]->set('name',        $_[1]); }
sub set_description { $_[0]->set('description', $_[1]); }
sub set_is_active   { $_[0]->set('is_active',   $_[1]); }

###############################
####      Subroutines    ######
###############################

sub get_all_with_bug_count {
  my $class = shift;
  my $dbh   = Bugzilla->dbh;
  my $user  = Bugzilla->user;

  # Only count bugs that are visible to the current user based on group
  # membership, so the counts don't leak the number of security-restricted
  # bugs (e.g. the sec-* and csectype-* keyword families) to users who can't
  # otherwise see them. A bug is hidden if it belongs to any group the user
  # is not a member of; we detect that with a LEFT JOIN and only count the
  # keyword rows that have no such group (bug_group_map.bug_id IS NULL).
  #
  # The reporter/assignee/qa/cc visibility exceptions (see
  # Bugzilla::User->visible_bugs) are intentionally not applied here: ignoring
  # them can only make a count lower than the user's true visibility, never
  # higher, so no restricted data can leak. Using a conditional COUNT (rather
  # than a WHERE clause) keeps keywords whose bugs are all restricted in the
  # result set with a count of 0, instead of dropping them entirely.
  my $keywords = $dbh->selectall_arrayref(
    'SELECT ' . join(', ', $class->_get_db_columns) . ',
                COUNT(CASE WHEN bug_group_map.bug_id IS NULL
                           THEN keywords.bug_id END) AS bug_count
                                  FROM keyworddefs
                             LEFT JOIN keywords
                                    ON keyworddefs.id = keywords.keywordid
                             LEFT JOIN bug_group_map
                                    ON keywords.bug_id = bug_group_map.bug_id
                                   AND bug_group_map.group_id NOT IN ('
      . $user->groups_as_string . ') '
      . $dbh->sql_group_by(
      'keyworddefs.id', 'keyworddefs.name,
                                                      keyworddefs.description'
      ) . '
                                 ORDER BY keyworddefs.name',
    {'Slice' => {}}
  );
  if (!$keywords) {
    return [];
  }

  foreach my $keyword (@$keywords) {
    bless($keyword, $class);
  }
  return $keywords;
}

###############################
###       Validators        ###
###############################

sub _check_name {
  my ($self, $name) = @_;

  $name = trim($name);
  if (!defined $name or $name eq "") {
    ThrowUserError("keyword_blank_name");
  }
  if ($name =~ /[\s,]/) {
    ThrowUserError("keyword_invalid_name");
  }

  # We only want to validate the non-existence of the name if
  # we're creating a new Keyword or actually renaming the keyword.
  if (!ref($self) || $self->name ne $name) {
    my $keyword = new Bugzilla::Keyword({name => $name});
    ThrowUserError("keyword_already_exists", {name => $name}) if $keyword;
  }

  return $name;
}

sub _check_description {
  my ($self, $desc) = @_;
  $desc = trim($desc);
  if (!defined $desc or $desc eq '') {
    ThrowUserError("keyword_blank_description");
  }
  return $desc;
}

sub _check_is_active { return $_[1] ? 1 : 0 }

sub is_active { return $_[0]->{is_active} }

1;

__END__

=head1 NAME

Bugzilla::Keyword - A Keyword that can be added to a bug.

=head1 SYNOPSIS

 use Bugzilla::Keyword;

 my $description = $keyword->description;

 my $keywords = Bugzilla::Keyword->get_all_with_bug_count();

=head1 DESCRIPTION

Bugzilla::Keyword represents a keyword that can be added to a bug.

This implements all standard C<Bugzilla::Object> methods. See
L<Bugzilla::Object> for more details.

=head1 METHODS

This is only a list of methods specific to C<Bugzilla::Keyword>.
See L<Bugzilla::Object> for more methods that this object
implements.

=over

=item C<get_all_with_bug_count()>

 Description: Returns all defined keywords. This is an efficient way
              to get the associated bug counts, as only one SQL query
              is executed with this method, instead of one per keyword
              when calling get_all and then bug_count.
 Params:      none
 Returns:     A reference to an array of Keyword objects, or an empty
              arrayref if there are no keywords.

=item C<is_security_keyword()>

 Description: Indicates if the keyword belongs to one of the security
              vulnerability keyword families (C<sec-*>, C<csec-*>,
              C<csectype-*>, C<wsec-*> and C<opsec-*>). Callers use this to
              decide whether the keyword's bug count may be shown to the
              current user. See C<SECURITY_KEYWORD_REGEX>.
 Params:      none
 Returns:     a boolean value that is true if the keyword is a security
              keyword.

=item C<is_active>

 Description: Indicates if the keyword may be used on a bug
 Params:      none
 Returns:     a boolean value that is true if the keyword can be applied to bugs.

=item C<set_is_active($is_active)>

 Description: Set the is_active property to a boolean value
 Params:      the new value of the is_active property.
 Returns:     nothing

=back

=cut
