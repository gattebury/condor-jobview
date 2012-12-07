#!/usr/bin/env perl

use strict;
use warnings;

use constant MINUTE => 60;
use constant HOUR   => 60 * MINUTE;
use constant DAY    => 24 * HOUR;

# -----------------
# Section [general]
# -----------------
our $config = 
{ 
         verbose => 1,
            site => q|T2_US_UCSD|,
           batch => q|Condor|,
   batch_version => q|7.2.x|,
         baseDir => q|/root/jobview_t2|, 
          domain => q|t2.ucsd.edu|,
       collector => q|osg-gw-1.t2.ucsd.edu|, 
#     schedd_list => [q|osg-gw-2.t2.ucsd.edu|, q|osg-gw-4.t2.ucsd.edu|], # if listed will take effect
     has_jobflow => 0,
        time_cmd => 1,
  show_cmd_error => 1,
      constraint => {
             'condor_q' => qq|SleepSlot =!= TRUE|,
        'condor_status' => qq|iam_sleep_slot==0|
      },
      show_table => { # all but the user tables shown by default (value:1)
              ce => 1,
            user => 1,
        priority => 1
      },
  privacy_enforced => 0,
    groups_dnshown => ['cms', 'cmsprod', 'samgrid', 'glowhtpc', 'other'],
   jobview_version => q|1.3.2|
};
$config->{html}   = qq|$config->{baseDir}/html/overview.html|;
$config->{xml}    = {save => 1, file => qq|$config->{baseDir}/html/overview.xml|};
$config->{xml_hf} = {
                              save => 1, 
                              file => qq|$config->{baseDir}/html/jobview.xml|, 
                      show_joblist => 1,
                           show_dn => 0};
$config->{json}   = {save => 1, file => qq|$config->{baseDir}/html/overview.json|};
# internal file based DB, fine as default
$config->{db} = 
{
   jobinfo => qq|$config->{baseDir}/db/jobinfo.db|,
      slot => qq|$config->{baseDir}/db/slots.db|,
  priority => qq|$config->{baseDir}/db/condorprio.db|,
      novm => qq|$config->{baseDir}/db/missing_vm.txt|
};
# --------------------
# Section [RRD]
# --------------------
$config->{rrd} = 
{
     verbose => 0, 
     enabled => 1, # _not_ used 
    location => qq|$config->{baseDir}/db|,
          db => qq|filen.rrd|,  # for global variables
        step => 180, # try to keep in sync with the cron job period
       width => 300,
      height => 100,
     comment => $config->{site},
  timeSlices =>
  [
    { ptag => 'lhour',  period =>      HOUR },
    { ptag => 'lday',   period =>       DAY },
    { ptag => 'lweek',  period =>   7 * DAY },
    { ptag => 'lmonth', period =>  30 * DAY },
    { ptag => 'lyear',  period => 365 * DAY }
  ],
  supportedGroups => 
  [ 
    'cms',     
    'cmsprod', 
    'cdf', 
    'samgrid',
    'other'
  ]
};

$config;
__END__
