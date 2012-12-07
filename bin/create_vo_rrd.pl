#!/usr/bin/env perl
package main;

use strict;
use warnings;

use ConfigReader;
use RRDsys;

# done only once
sub main
{
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $voList = $config->{rrd}{supportedGroups};

  for my $vo (@$voList) {
    my $rrd = new RRDsys({ file => qq|$vo.rrd| });
    $rrd->create(['runningJobs', 'pendingJobs', 'cpuEfficiency']);
  }
}

# Execute
main;
__END__
