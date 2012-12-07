package JobInfo;

use strict;
use warnings;
use Carp;
use HTTP::Date;
use Data::Dumper;

use Util qw/trim getCommandOutput/;
use ConfigReader;

$JobInfo::VERSION = q|0.1|;

our $AUTOLOAD;
my %fields = map { $_ => 1 } 
      qw/JID
         GRID_ID
         LOCAL_ID
         USER
         GROUP
         QUEUE
         STATUS
         LSTATUS
         QTIME
         START
         END
         EXEC_HOST
         CPUTIME
         WALLTIME
         MEM
         VMEM
         EX_ST
         CPULOAD
         JOBDESC
         ROLE
         GRID_CE
         SUBJECT
         TIMELEFT/;

use constant SCALE => 1024;
our $conv =
{
  K => SCALE,
  M => SCALE**2,
  G => SCALE**3
};
our $statusAttr = 
{
   2 => [q|R|, q|running|],
   1 => [q|Q|, q|pending|],
   4 => [q|E|, q|exited|],
   3 => [q|E|, q|exited|],
   5 => [q|H|, q|held|]
};
sub new
{
  my ($this, $attr) = @_;
  my $class = ref $this || $this; 

  bless {
     _permitted => \%fields
  }, $class;
}

sub parse
{
  my ($self, $attr) = @_;
  
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $verbose    = $config->{verbose} || 0;
  my $domain     = $config->{domain};
  my $collector  = $config->{collector};
  my $show_error = $config->{show_cmd_error} || 0;
  my $group_map  = $config->{group_map} || {};

  my @lines;
  if (defined $attr->{text}) { 
    my $text = $attr->{text};
    @lines = split /\n/, $$text;
  }
  else {
    croak q|Must specify a valid JOBID| unless defined $attr->{jobid};
    my $user = (defined $attr->{user} && $attr->{user} !~ /^all$/) ? "-submitter $attr->{user}" : q||;

    my $command = qq|condor_q -global -pool $collector $user -l $attr->{jobid}|;
    my $ecode = 0;
    chomp(@lines = getCommandOutput($command, \$ecode, $show_error, $verbose));
  }

  my $parse_opt = $attr->{parse_opt} || 1;    
  my $info = ($parse_opt > 0) ? __PACKAGE__->_parse_split(\@lines) 
                              : __PACKAGE__->_parse_match(\@lines);

  # Normalise 
  $info->{JID}      =~ s/#/_/g if defined $info->{JID}; 
  my $status = $info->{STATUS};
  $info->{STATUS}   = $statusAttr->{$status}[0] || undef; 
  $info->{LSTATUS}  = $statusAttr->{$status}[1] || undef; 
  $info->{LOCAL_ID} = (defined $info->{CLUSTER_ID} and defined $info->{PROC_ID})
                         ? qq|$info->{CLUSTER_ID}.$info->{PROC_ID}| 
                         : undef;

  
  my $group =  __PACKAGE__->correctGroup({  user => $info->{USER}, 
                                           group => $info->{GROUP},
			                  ugdict => $attr->{ugdict}});
  # Some parameters are still missing
  $info->{GROUP} = $group;
  $info->{ROLE}  = $info->{GROUP};
  $info->{QUEUE} = $info->{GROUP};

  $info->{GRID_ID} = $info->{JID}; 
  my $ceid = (split /_/, $info->{GRID_ID})[0];
  $info->{GRID_CE} = $ceid.q|/jobmanager-condor-|.$info->{QUEUE};

  # patch walltime
  my $timenow = time();
  if ((defined $info->{STATUS} and $info->{STATUS} eq 'R') 
        and (not defined $info->{WALLTIME} or $info->{WALLTIME} <= 0)) {
    if (defined $info->{START}) {
      my $startTime = $info->{START};
      $info->{WALLTIME} = $timenow - $startTime;
      my $cpuload = (defined $info->{CPUTIME}) ? $info->{CPUTIME}*1.0/$info->{WALLTIME} : undef;
      $info->{CPULOAD} = (defined $cpuload) ? sprintf ("%.3f", $cpuload) : undef;
    }
  }
  $info->{TIMELEFT} = (defined $info->{TIMELEFT}) ? $timenow + 36 * 3600 - $info->{TIMELEFT} : undef;
  $self->{_INFO} = $info;
}

sub correctGroup
{
  my ($pkg, $attr) = @_;
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $verbose   = $config->{verbose} || 0;
  my $group_map = $config->{group_map} || {};

  my $user  = $attr->{user};
  my $group = $attr->{group};
  if (defined $group and length $group) {
    $group = (split /\./, $group)[0];
    $group =~ s/group_//;
  }
  elsif (defined $attr->{ugdict}{$user}) {
    $group = $attr->{ugdict}{$user}; 
  }
  elsif (scalar keys (%$group_map)) {
    print "INFO. Group for $user undefined, use group_map\n" if $verbose;
    my @userp = sort keys %$group_map;
    for my $patt (@userp) {
      if ($user =~ m/$patt/) {
        $group = $group_map->{$patt};
        $attr->{ugdict}{$user} = $group; 
        print ">>> group=$group\n" if $verbose;
        last;
      }
    } 
  }
  else {
    $group = q|unknown|; 
  }
  $group;
}
sub _parse_split
{
  my ($pkg, $lines) = @_;
  my $keymap = 
  {
                ClusterId => q|CLUSTER_ID|,
                   ProcId => q|PROC_ID|,
              GlobalJobId => q|JID|,
                    Owner => q|USER|,
                JobStatus => q|STATUS|,
                    QDate => q|QTIME|,
               RemoteHost => q|EXEC_HOST|,
      JobCurrentStartDate => q|START|,
           CompletionDate => q|END|,
      RemoteWallClockTime => q|WALLTIME|, 
            RemoteUserCpu => q|CPUTIME|,
            ImageSize_RAW => q|MEM|, 
                DiskUsage => q|VMEM|,
          AccountingGroup => q|GROUP|,
     x509userproxysubject => q|SUBJECT|,
               ExitStatus => q|EX_ST|,
                      Cmd => q|JOBDESC|,
     EnteredCurrentStatus => q|TIMELEFT|
  };
  my $info = {};
  for my $line (@$lines)  {
    next if $line =~ /^$/;         # Skip empty lines
    $line =~ s/"//g;
    my ($key, $value) = (split /\s+=\s+/, trim $line);
    next unless exists $keymap->{$key};
    $info->{$keymap->{$key}} = $value;
  }
  $info;
}
sub _parse_match
{
  my ($pkg, $lines) = @_;
  my $reader = ConfigReader->instance();
  my $config = $reader->config;
  my $domain = $config->{domain};

  my $info = {};
  for (@$lines)  {
    next if /^$/;         # Skip empty lines
    s/"//g;
    if (/^ClusterId = (\d+)/) {
      $info->{CLUSTER_ID} = $1;
    } elsif (/^ProcId = (\d+)/) {
      $info->{PROC_ID} = $1;
    } elsif (/^GlobalJobId = (.*)/) {
      $info->{JID} = $1;
    } elsif (/^Owner = (.*)/) {
      $info->{USER} = $1; 
    } elsif (/^JobStatus = (\d+)/) {
      $info->{STATUS} = $1;
    } elsif (/(.*?)-- Schedd: (.*?) : /) {
      $info->{QUEUE} = $1;
    } elsif (/^QDate = (\d+)/) {
      $info->{QTIME} = $1; 
    } elsif (/^RemoteHost = (.*)/) {
      my $host = $1; $host =~ s/\.$domain//;
      $info->{EXEC_HOST} = $host;
    } elsif (/^JobCurrentStartDate = (\d+)/) {
      $info->{START} = $1;
    } elsif (/^CompletionDate = (\d+)/) {
      $info->{END} = $1;
    } elsif (/^RemoteWallClockTime = (.*)/) {
      $info->{WALLTIME} = int($1) || 0; 
    } elsif (/^RemoteUserCpu = (.*)/) {
      $info->{CPUTIME} = int($1) || 0; 
    } elsif (/^ImageSize_RAW = (\d+)/) {
      $info->{MEM} = $1; 
    } elsif (/^DiskUsage = (\d+)/) {
      $info->{VMEM} = $1; 
    } elsif (/^AccountingGroup = (.*)/) {
      $info->{GROUP} = $1;
    } elsif (/^x509userproxysubject = (.*)/) {
      $info->{SUBJECT} = $1;
    } elsif (/^ExitStatus = (\d+)/) {
      $info->{EX_ST} = $1;
    } elsif (/^Cmd = (.*)/) {
      $info->{JOBDESC} = $1;
    } elsif (/^EnteredCurrentStatus = (\d+)/) {
      $info->{TIMELEFT} = time() + 36 * 3600 - $1;
    }
  }
  $info;  
}
sub setStatus
{
  my ($self, $status) = @_;
  $self->{_INFO}{LSTATUS} = $statusAttr->{$status}[1] || undef;
  $self->{_INFO}{STATUS}  = $statusAttr->{$status}[0] || undef;
}

sub info
{
  my $self = shift;
  $self->{_INFO};
}

sub dump
{
  my $self = shift;
  my $info = $self->info;
  print Data::Dumper->Dump([$info], [qw/jobinfo/]);
}
sub show
{
  my $self = shift;
  my $stream = shift || *STDOUT;
  print $stream $self->toString;
}

sub toString
{
  my $self = shift;
  my $info = $self->info;
  my $output = sprintf (qq|\n{%s}{%s}{%s}\n|, $info->{GROUP}, $info->{QUEUE}, $info->{JID});
  while ( my ($key) = each %$info ) {
    $output .= sprintf(qq|%s: %s\n|, $key, $info->{$key});
  }
  $output;
}

sub AUTOLOAD 
{
  my $self = shift;
  my $type = ref $self or croak qq|$self is not an object|;

  my $name = $AUTOLOAD;
  $name =~ s/.*://;   # strip fully-qualified portion

  croak qq|Failed to access $name field in class $type| 
    unless exists $self->{_permitted}{$name};

  if (@_) {
    return $self->{_INFO}{$name} = shift;
  } 
  else {
    return ((defined $self->{_INFO}{$name}) 
      ? $self->{_INFO}{$name} 
      : undef);
  }
}

sub DESTROY
{
  my $self = shift;
}

1;
__END__
package main;

my $jid = shift || die qq|Usage $0 JID|;
my $job = new JobInfo({jobid => $jid});
$job->show;
