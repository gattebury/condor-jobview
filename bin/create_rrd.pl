#!/usr/bin/env perl
package main;

use strict;
use warnings;

use ConfigReader;
use RRDsys;

sub main
{
  # done only once
  my $reader = ConfigReader->instance();
  my $config = $reader->config;

  my $file = qq|$config->{rrd}{db}|;
  my $rrd = new RRDsys({ file => $file });
  $rrd->create(['totalCPU', 'freeCPU', 'runningJobs', 'pendingJobs', 'cpuEfficiency']);
}

# Execute
main;
__END__
