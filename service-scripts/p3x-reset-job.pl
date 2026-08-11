=head1 NAME
    
    p3x-reset - reset a job back to queued state
    
=head1 SYNOPSIS

    p3x-qdel [OPTION] jobid [jobid...]
    
=head1 DESCRIPTION

Resets a job back to be queued state.

=cut

use strict;
use Data::Dumper;
use JSON::XS;
use Bio::KBase::AppService::SchedulerDB;
use Time::Duration::Parse;
use IPC::Run qw(run);

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["time|t=s" => "Reset the requested duration"],
				    ["memory|m=s" => "Reset the requested memory"],
				    ["cpu|c=s" => "Reset the requested number of cpus"],
				    ["storage|s=s" => "Reset the requested storage (bytes)"],
				    ["data-container|D=s" => "Reset the requested data container"],
				    ["container|C=s" => "Reset the requested runtime container"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV == 0;

my $time;
if ($opt->time =~ /^(\d+)-(\S+)$/)
{
    my $days = $1;
    my $ts = $2;
    $time = eval { parse_duration($ts); };
    die "Cannot parse '$ts': $@" unless defined($time);
    $time += $days * 86400;
}
elsif ($opt->time)
{
    $time = eval { parse_duration($opt->time); };
    die "Cannot parse '" . $opt->time . "'" unless defined($time);
}

my $storage;
if ($opt->storage)
{
    my $s = $opt->storage;
    if ($s =~ /^(\d+(?:\.\d+)?)\s*([TGMK])B?$/i)
    {
	my %mult = (T => 1e12, G => 1e9, M => 1e6, K => 1e3);
	$storage = int($1 * $mult{uc $2});
    }
    elsif ($s =~ /^\d+$/)
    {
	$storage = $s + 0;
    }
    else
    {
	die "Cannot parse storage '$s' (use e.g. 50G, 1.5T, 500M, or bytes)\n";
    }
}

my $db = Bio::KBase::AppService::SchedulerDB->new();

my @task_ids;

foreach (@ARGV)
{
    if (/^(\d+),?$/)
    {
	push(@task_ids, $1);
    }
    else
    {
	die "Invalid task id $_\n";
    }
}

for my $task (@task_ids)
{
    remove_output_folder($task);

    $db->reset_job($task, {
       ($time ? (time => $time) : ()),
       ($opt->memory ? (memory => $opt->memory) : ()),
       ($opt->cpu ? (cpu => $opt->cpu) : ()),
       ($storage ? (storage => $storage) : ()),
       ($opt->data_container ? (data_container_id => $opt->data_container) : ()),
       ($opt->container ? (container_id => $opt->container) : ()),
   });
}

sub remove_output_folder
{
    my($task) = @_;

    my @qstat_cmd = ('p3x-qstat', '--show-output-file', '--show-output-path', '--parsable', '--no-header', $task);
    my $qstat_out;
    my $ok = run(\@qstat_cmd, '>', \$qstat_out, '2>', \my $qstat_err);
    if (!$ok)
    {
	warn "Error running @qstat_cmd: $qstat_err\n";
	return;
    }

    my($line) = split(/\n/, $qstat_out);
    if (!$line)
    {
	warn "No qstat output found for job $task; not removing output folder\n";
	return;
    }

    my @fields = split(/\t/, $line);
    my $output_file = $fields[-2];
    my $output_path = $fields[-1];
    if (!$output_file || !$output_path)
    {
	warn "Could not determine output path for job $task; not removing output folder\n";
	return;
    }

    my $folder = "$output_path/.$output_file";

    my @rm_cmd = ('p3-rm', '-A', '-r', $folder);
    my $rm_err;
    $ok = run(\@rm_cmd, '2>', \$rm_err);
    if (!$ok)
    {
	warn "Error removing output folder $folder for job $task: $rm_err\n";
    }
}
