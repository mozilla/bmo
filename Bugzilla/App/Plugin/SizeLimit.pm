# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::App::Plugin::SizeLimit;
use 5.10.1;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::JSON qw(decode_json);
use Bugzilla::Logging;

use constant MIN_SIZE_LIMIT    => 750_000;
use constant PROC_STATUS       => '/proc/self/status';
use constant HAVE_BSD_RESOURCE => eval { require BSD::Resource };

BEGIN {
  if (HAVE_BSD_RESOURCE) {
    BSD::Resource->import;
  }
}

my @RESOURCES = qw(
  RLIMIT_CPU RLIMIT_FSIZE RLIMIT_DATA RLIMIT_STACK RLIMIT_CORE RLIMIT_RSS RLIMIT_MEMLOCK RLIMIT_NPROC RLIMIT_NOFILE
  RLIMIT_OFILE RLIMIT_OPEN_MAX RLIMIT_LOCKS RLIMIT_AS RLIMIT_VMEM RLIMIT_PTHREAD RLIMIT_TCACHE RLIMIT_AIO_MEM
  RLIMIT_AIO_OPS RLIMIT_FREEMEM RLIMIT_NTHR RLIMIT_NPTS RLIMIT_RSESTACK RLIMIT_SBSIZE RLIMIT_SWAP RLIMIT_MSGQUEUE
  RLIMIT_RTPRIO RLIMIT_RTTIME RLIMIT_SIGPENDING
);

my %RESOURCE;
if (HAVE_BSD_RESOURCE) {
  $RESOURCE{$_} = eval $_ for @RESOURCES;
}

sub register {
  my ($self, $app, $conf) = @_;

  if (HAVE_BSD_RESOURCE) {
    my $setrlimit = decode_json(Bugzilla->localconfig->setrlimit);

    # This trick means the master process will not a size limit.
    Mojo::IOLoop->next_tick(sub {
      foreach my $resource (keys %$setrlimit) {
        setrlimit(
          $RESOURCE{$resource},
          $setrlimit->{$resource},
          $setrlimit->{$resource}
        );
      }
    });
  }

  if (defined vm_size_kb()) {
    my $size_limit = Bugzilla->localconfig->size_limit;
    return unless $size_limit;

    if ($size_limit < MIN_SIZE_LIMIT) {
      WARN(sprintf "size_limit cannot be smaller than %d", MIN_SIZE_LIMIT);
      $size_limit = MIN_SIZE_LIMIT;
    }

    $app->hook(
      after_dispatch => sub {
        my $c    = shift;
        my $size = vm_size_kb() // return;
        if ($size >= $size_limit) {
          my $diff = $size - $size_limit;
          INFO("memory size exceeded $size_limit by $diff ($size)");
          $c->res->headers->connection('close');
          Mojo::IOLoop->singleton->stop_gracefully;
        }
      }
    );
  }
}

# Virtual memory size of this process in kB, or undef if unavailable (non-Linux).
#
# This is the same total that Linux::Smaps::Tiny reports as {Size} (the sum of
# every mapping's Size), but the kernel keeps it precomputed in VmSize, so this
# reads a few dozen lines instead of parsing all of /proc/self/smaps (tens of
# thousands of lines in a BMO worker) after every request. Linux::Smaps::Tiny
# 0.10 also silently fell back to its pure-Perl parser: its XS loader runs in a
# BEGIN block before $VERSION is set, so the version check always failed.
sub vm_size_kb {
  open my $fh, '<', PROC_STATUS or return undef;
  my $size;
  while (my $line = <$fh>) {
    if ($line =~ /^VmSize:\s+(\d+)\s+kB/) {
      $size = $1;
      last;
    }
  }
  close $fh;
  return $size;
}

1;
