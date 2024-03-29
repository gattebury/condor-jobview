package Overview;

use strict;
use warnings;

use POSIX qw/strftime/;
use Data::Dumper;
$Data::Dumper::Purity = 1;
use List::Util qw/max min/;
use File::stat;

use Util qw/trim 
            show_message 
            commandFH
            getCommandOutput 
            storeInfo 
            restoreInfo/;
use ConfigReader;
use JobList;
use JobInfo;

our $smap = 
{
  R => q|nrun|,
  Q => q|npend|,
  H => q|nheld|
};

sub new
{
  my $this = shift;
  my $class = ref $this || $this;

  my $self = bless {}, $class;
  $self->_initialize;
  $self;
}
sub _initialize
{
  my $self = shift;
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $time_cmd  = $config->{time_cmd} || 0;
  my $verbose   = $config->{verbose} || 0;
  my $collector = $config->{collector};
  my $slotDB    = $config->{db}{slot} || qq|$config->{baseDir}/db/slots.db|;

  # Batch slots
  # time the Condor commands
  my $time_a = time;
  my $command = <<"END";
condor_status -pool $collector \\
    -format "%s!" Name \\
    -format "%s!" State \\
    -format "%s!" GlobalJobId \\
    -format "%d!" TotalMemory \\
    -format "%f!" TotalLoadAvg \\
    -format "%d\\n" MyCurrentTime \\
    -constraint 'State != "Owner"' \\
END
  $command .= qq| -constraint '$config->{constraint}{condor_status}'| 
    if defined $config->{constraint}{condor_status};
  print STDERR $command, "\n" if $verbose;

  my ($total, $claimed, $unclaimed) = (0,0,0);
  my $dict = {};
  my $fh = commandFH($command, $verbose);
  if (defined $fh) {
    while (my $line = $fh->getline) {
      next if $line =~ /^$/;
      ++$total; 
      my ($name, $state, $jid, $memory, $load, $time) = (split /!/, trim $line);
      ($state eq 'Claimed') ? ++$claimed : ++$unclaimed;
      $name =~ s/\@/-/;
      $dict->{$name} = {
                 State => $state,
           GlobalJobId => $jid,
           TotalMemory => $memory,
          TotalLoadAvg => $load,
         MyCurrentTime => $time
      };
    }
    $fh->close;
  }
  show_message q|>>> Overview::condor_status: elapsed time = |. (time() - $time_a) . q| second(s)|
    if $time_cmd;
  
  my $max = $self->updateSlotDB($dict);
  my $slots = {
          max => $max,
    available => $total,
      running => $claimed,
         free => $unclaimed
  };

  my $jobinfo = {njobs => 0,
                  nrun => 0,
                 npend => 0,
                 nheld => 0,
               cputime => 0,
              walltime => 0,
               ratio10 => 0};
  my $userinfo  = {};
  my $groupinfo = {};
  my $ceinfo    = {};
  my $jobs = new JobList;
  my $joblist = $jobs->list; # returns a hash reference
  while ( my ($jid, $job) = each %$joblist ) {
    my $dn     = $job->SUBJECT;
    my $user   = $job->USER;
    my $status = $job->STATUS;
    my $group  = $job->GROUP;
    my $ceid   = $job->GRID_CE;
    my $ce     = (split m#\/#, $ceid)[0];

    $jobinfo->{njobs}++;
    $groupinfo->{$group}{njobs}++;
    $ceinfo->{$ce}{njobs}++;
    $userinfo->{$dn}{njobs}++;
    $userinfo->{$dn}{user}  = $user  unless exists $userinfo->{$dn}{user};
    $userinfo->{$dn}{group} = $group unless exists $userinfo->{$dn}{group};

    defined $smap->{$status} or next;
    my $tag = $smap->{$status};
    $jobinfo->{$tag}++;
    $groupinfo->{$group}{$tag}++;
    $ceinfo->{$ce}{$tag}++;
    $userinfo->{$dn}{$tag}++;
    if ($status eq 'R') {
      my $cputime  = $job->CPUTIME  || 0.0;
      my $walltime = $job->WALLTIME || 0.0;

      $jobinfo->{cputime}  += $cputime;
      $jobinfo->{walltime} += $walltime;

      $groupinfo->{$group}{cputime}  += $cputime;
      $groupinfo->{$group}{walltime} += $walltime;

      $ceinfo->{$ce}{cputime}  += $cputime;
      $ceinfo->{$ce}{walltime} += $walltime;

      $userinfo->{$dn}{cputime}  += $cputime;
      $userinfo->{$dn}{walltime} += $walltime;

      my $ratio = min 1, (($walltime>0) ? $cputime/$walltime : 0);
      if ($ratio < 0.1) {
        ++$jobinfo->{ratio10};
        ++$groupinfo->{$group}{ratio10};
        ++$ceinfo->{$ce}{ratio10};
        ++$userinfo->{$dn}{ratio10};
      }
    }
  }
  for my $info ($groupinfo, $ceinfo, $userinfo) {
    for my $el (keys %$info) {
      $info->{$el}{njobs}    = 0 unless defined $info->{$el}{njobs};
      $info->{$el}{nrun}     = 0 unless defined $info->{$el}{nrun};
      $info->{$el}{npend}    = 0 unless defined $info->{$el}{npend};
      $info->{$el}{nheld}    = 0 unless defined $info->{$el}{nheld};
      $info->{$el}{cputime}  = 0 unless (defined $info->{$el}{cputime} and $info->{$el}{cputime}>0);
      $info->{$el}{walltime} = 0 unless (defined $info->{$el}{walltime} and $info->{$el}{walltime}>0);
      $info->{$el}{ratio10}  = 0 unless defined $info->{$el}{ratio10};
    }
  }

  if ($verbose>1) {
    print Data::Dumper->Dump([$slots],     [qw/slots/]); 
    print Data::Dumper->Dump([$jobinfo],   [qw/jobinfo/]); 
    print Data::Dumper->Dump([$ceinfo],    [qw/ceinfo/]);
    print Data::Dumper->Dump([$groupinfo], [qw/groupinfo/]);
    print Data::Dumper->Dump([$userinfo],  [qw/userinfo/]);
  }
  # now add them to the object
  $self->{slots}     = $slots;
  $self->{jobinfo}   = $jobinfo;
  $self->{groupinfo} = $groupinfo;
  $self->{ceinfo}    = $ceinfo;
  $self->{userinfo}  = $userinfo;
  $self->{joblist}   = $joblist;
}

sub updateSlotDB
{
  my ($self, $info) = @_;
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $slotDB = $config->{db}{slot} || qq|$config->{baseDir}/db/slots.db|;
  my $novm   = $config->{db}{novm} || qq|$config->{baseDir}/db/missing_vm.txt|;
  my $mentries = 0;
  if ( -r $slotDB ) {
    my $dbinfo = restoreInfo($slotDB);
    my $neli   = scalar keys %$dbinfo; 

    # present in DB but not in the present iteration
    open OUTPUT, ">$novm" or die qq|Failed to open output file $novm!|;
    for my $el (sort keys %$dbinfo) {
      unless (exists $info->{$el}) { 
        my $vm = $el;  
        $vm =~ s/-/\@/;
        printf OUTPUT "%34s|%10s|%40s|%8d|%7.3f|%d\n", 
            $vm, 
            $dbinfo->{$el}{State},
            $dbinfo->{$el}{GlobalJobId},
            $dbinfo->{$el}{TotalMemory},
    	    $dbinfo->{$el}{TotalLoadAvg},
            $dbinfo->{$el}{MyCurrentTime} || 0;
      }
    }
    close OUTPUT;
    
    # present in the present iteration but not in DB
    for my $el (sort keys %$info) {
      exists $dbinfo->{$el} or $dbinfo->{$el} = $info->{$el};
    }
    my $nelj = scalar keys %$dbinfo; 
    storeInfo($slotDB, $dbinfo) if $nelj > $neli;
    $mentries = max $neli, $nelj;
  }
  else {
    storeInfo($slotDB, $info);
    $mentries = scalar keys %$info;
  }
  $mentries;
}

sub getPriority
{
  my $self = shift;
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $priorityDB = $config->{db}{priority} || qq|$config->{baseDir}/db/condorprio.db|;

  my $output = '';
  if ( -r $priorityDB and file_age($priorityDB) < 3600) {
    print ">>> Overview::getPriority: read priority table from cache $priorityDB\n";
    my $info = restoreInfo($priorityDB);
    $output = $info->{text};
  }
  else {
    my $collector = $config->{collector};
    my $command = <<"END";
condor_userprio -pool $collector -all
END
    my $ecode = 0; 
    chop($output = getCommandOutput($command, \$ecode));
    my $info = {text => $output};
    storeInfo($priorityDB, $info);
  }
  $output;
}
sub file_age
{
  my $file = shift;
  time() - stat($file)->mtime;
}

1;
__END__
my $obj = new Overview;
