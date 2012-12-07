package JobList;

use strict;
use warnings;
use Carp;
use Storable;
use POSIX qw/strftime/;
use Data::Dumper;
use List::Util qw/min/;

use ConfigReader;
use JobInfo;
use Util qw/trim 
            show_message
            commandFH
            getCommandOutput 
            readFile 
            storeInfo
            restoreInfo
            findGroup/;

$JobList::VERSION = q|0.1|;

sub new
{
  my ($this, $attr) = @_;
  my $class = ref $this || $this; 

  my $self = bless {
   _list => {}
  }, $class;

  $self->_initialize($attr);
  my $dict = $self->list;
  unless (scalar keys %$dict) {
    # Read the values from last iteration
    my $reader = ConfigReader->instance();
    my $config = $reader->config;
    my $dbfile = $config->{db}{jobinfo} || qq|$config->{baseDir}/db/jobinfo.db|;
    show_message qq|>>> condor_q [-l] failed! retrieve information from $dbfile|;
    $self->list(restoreInfo($dbfile));
  }
  $self;
}

sub list
{
  my $self = shift;
  if (@_) {
    return $self->{_list} = shift;
  } 
  else {
    return $self->{_list};
  }
}
sub show
{
  my $self = shift;
  my $stream = shift || *STDOUT;
  my $joblist = $self->list; # returns a hash reference
  for my $job (values %$joblist) {
    $job->show($stream);
  }
}

sub toString
{
  my $self = shift;
  my $output = q||;
  my $joblist = $self->list; # returns a hash reference
  for my $job (values %$joblist) {
    $output .= $job->toString;
  }
  $output;
}
sub _initialize
{
  my ($self, $attr) = @_;

  my $dict = {};
  $self->list($dict);

  # Read the config in any case
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $collector  = $config->{collector};
  my $slist = '';
  my $scheddList = $config->{schedd_list} || [];
  $slist = qq| -name $_| for (@$scheddList);
  my $verbose    = $config->{verbose} || 0;
  my $time_cmd   = $config->{time_cmd} || 0;
  my $show_error = $config->{show_cmd_error} || 0;
  my $batch_v    = $config->{batch_version} || '7.2.x';

  # time the Condor command execution
  # We should call condor_q -l only for running jobs
  my $time_a = time();
  my $command = qq|condor_q -l -pool $collector -constraint 'jobstatus == 2'|;
  $command .= qq| -constraint '$config->{constraint}{condor_q}'| 
    if defined $config->{constraint}{condor_q};
  # Finally, if instructed query only the listed schedds
  $command .= (scalar @$scheddList) ? $slist : q| -global|;
  print STDERR $command, "\n", if $verbose;

  my $ecode = 0;
  chop(my $text = getCommandOutput($command, \$ecode, $show_error, $verbose));
  show_message q|>>> JobList::condor_q -r -l |.
    qq|exit code: $ecode; elapsed time = |. (time() - $time_a) . q| second(s)| if $time_cmd;
  return if $ecode;

  my $nRun = 0;
  my $sep = ($batch_v =~ /7\.2\.\S/) ? 'MyType = "Job"' : 'ServerTime = ';
  chomp(my @jobList = split /$sep/, $text);
  (($batch_v =~ /7\.2\.\S/) ? shift @jobList : pop @jobList);

  my $ugDict = {};
  for my $jInfo (@jobList) {
    # We already have the long listing on the job at our disposal
    my $job = new JobInfo;
    $job->parse({ text => \$jInfo, ugdict => $ugDict });
    $dict->{$job->JID} = $job;
    ++$nRun;
  }

  # Add missing information using condor_status 
  $time_a = time();
  $command = <<"END";
condor_status -pool $collector \\
       -format "%s!" GlobalJobId \\
       -format "%d!" TotalJobRunTime \\
       -format "%.3f\\n" TotalCondorLoadAvg \\
       -constraint 'State=="Claimed" && Activity=="Busy"' \\
END
  $command .= qq| -constraint '$config->{constraint}{condor_status}'| 
    if defined $config->{constraint}{condor_status};
  print STDERR $command, "\n", if $verbose;

  my $fh = commandFH($command, $verbose);
  if (defined $fh) {
    while ( my $line = $fh->getline) {
      my (@fields) = (split /!/, trim $line);
      next unless scalar @fields > 2;

      my $jid = join '_', (split /#/, $fields[0]);
      next unless defined $dict->{$jid};

      my $job = $dict->{$jid};
      my $walltime = $fields[1];
      my $cputime = min $walltime, ($job->CPUTIME || 0);
      $job->CPUTIME($cputime);
      my $cpuload = ($walltime > 0) ? $job->CPUTIME*1.0/$walltime : 0.0;
      $cpuload = sprintf "%.3f", $cpuload;
      printf STDERR qq|JID=%s,status=%s,cputime=%d,walltime=%d,cpuload=%.3f\n|,
         $jid, $job->STATUS, 
               $job->CPUTIME,
               $walltime,
               $cpuload if $verbose>1;
      $job->CPULOAD($cpuload);
      $job->WALLTIME($walltime);

      $job->dump if $verbose>1;
    }
    $fh->close;
  }
  show_message q|>>> JobList::condor_status: elapsed time = |. (time() - $time_a) . q| second(s)|
    if $time_cmd;

  # Now queued and held jobs
  my $nJobs = $nRun;
  $time_a = time();
  $command = <<"END";
condor_q -pool $collector \\
      -format "%d." ClusterId \\
      -format "%d!" ProcId \\
      -format "%d!" JobStatus \\
      -format "%s!" Owner \\
      -format "%s!" x509userproxysubject \\
      -format "%s!" GlobalJobId \\
      -format "%d!" QDate \\
      -format "%s!" AccountingGroup \\
      -format "%s\\n" Owner \\
      -constraint 'jobstatus == 1 || jobstatus == 5' \\
END
  $command .= qq| -constraint '$config->{constraint}{condor_q}'| 
    if defined $config->{constraint}{condor_q};
  # Finally, if instructed query only the listed schedds
  $command .= (scalar @$scheddList) ? $slist : q| -global|;
  print STDERR $command, "\n", if $verbose;

  $fh = commandFH($command, $verbose);
  if (defined $fh) {
    while (my $line = $fh->getline) {
      my ($jid, $status, $user, $subject, $globalid, $qtime, $acgroup) 
         = (split /!/, trim $line); # the last ProcId helps 

      $acgroup eq $user and $acgroup = undef;
      my $group = JobInfo->correctGroup({  user => $user, 
                                          group => $acgroup,
		                         ugdict => $ugDict});
      my $queue = $group;
      my $ce = (defined $globalid) ? (split /#/, $globalid)[0] : undef;
      my $gridce = (defined $ce) ? $ce.q|/jobmanager-condor-|.$queue : undef;

      my $job = new JobInfo;
      $globalid =~ s/#/_/g;
      $job->JID($globalid);
      $job->USER($user);
      $job->QUEUE($queue);
      $job->GROUP($group);
      $job->GRID_CE($gridce);
      $job->SUBJECT($subject);
      $job->setStatus($status);
      $job->QTIME($qtime);

      $dict->{$job->JID} = $job;
      $job->dump if $verbose>1;

      ++$nJobs;
    }
    $fh->close;
  }
  show_message q|>>> JobList::condor_q: elapsed time = |. (time() - $time_a) . q| second(s)|
    if $time_cmd;
  show_message qq|>>> Processed nJobs=$nJobs,nRun=$nRun|;

  # save in a storable
  my $dbfile = $config->{db}{jobinfo} || qq|$config->{baseDir}/db/jobinfo.db|;
  storeInfo($dbfile, $dict);

  print Data::Dumper->Dump([$ugDict], [qw/ugDict/]) if $verbose;
}

1;
__END__
package main;
my $job = new JobList;
$job->show;
