#
# Given a spreadsheet as generated by p3x-run-qa-suite.pl updated any rows
# that are missing status data.
#

use strict;
use Getopt::Long::Descriptive;
use Bio::KBase::AppService::Client;
use File::Slurp;
use JSON::XS;
use File::Basename;
use Data::Dumper;
use Bio::KBase::AppService::LongestCommonSubstring qw(BuildString BuildTree LongestCommonSubstring);
use HTML::QuickTable;
use HTML::Table;

my $cli = Bio::KBase::AppService::Client->new;

my($opt, $usage) = describe_options("%c %o input-file",
				    ["output-file|o=s" => "Write output here"],
				    ["html-dir|D=s" => "Write HTML output to this directory, named based on the input file"],
				    ["html-file|H=s" => "Write HTML output here"],
				    ["help|h" => "Show this help message"]);
$usage->die() if @ARGV != 1;
print($usage->text), exit 0 if $opt->help;

my $input_file = shift;

open(IN, "<", $input_file) or die "Cannot read $input_file: $!";

my $out_fh = \*STDOUT;
if ($opt->output_file)
{
    undef $out_fh;
    open($out_fh, ">", $opt->output_file) or die "Cannot write output " . $opt->output_file . ": $!";
}

my @out;

while (<IN>)
{
    chomp;
    my($tag, $container, $app, $task_id, $inp_fn, $out_fs, $out_ws_file, $out_ws_folder, $task_exit, $qa_success, $elap, $host, $dc, $rss) = split(/\t/);

    next unless -f $inp_fn;
    if ($task_exit eq '')
    {
	my $det = $cli->query_task_details($task_id);
	$host = $det->{hostname};
	my $task = $cli->query_tasks([$task_id])->{$task_id};

	my $need_rss = !defined($rss);
	if ($task->{status} eq 'completed' || $task->{status} eq 'failed')
	{
	    $elap = $task->{elapsed_time};

	    $need_rss = 1;
	}
	if ($need_rss)
	{
	    if (open(R, "-|", "p3x-qstat", "--no-header", "--parsable", $task_id))
	    {
		my $l = <R>;
		chomp $l;
		my(@a) = split(/\t/, $l);
		$rss = $a[13];
		close(R);
	    }
	}

	if (defined($det->{exitcode}))
	{
	    $task_exit = $det->{exitcode};

	    my $params = decode_json(scalar read_file($inp_fn));

	    $qa_success = (($task_exit == 0) xor $params->{failure_expected}) ? "OK" : "FAIL";
	}
	else
	{
	    $qa_success = $task->{status};
	    if ($qa_success eq 'completed')
	    {
		warn Dumper($det);
	    }
	}
    }
    my $link = qq(<a href="https://bv-brc.org/workspace$out_ws_folder/.$out_ws_file">$out_ws_file</a>);
    push(@out, [$tag, $container, $app, $task_id, $inp_fn, $out_fs, $out_ws_file, $out_ws_folder, $task_exit, $qa_success, $elap, $host, $link, $rss]);
#    print $out_fh join("\t", $tag, $container, $app, $task_id, $inp_fn, $out_fs, $out_ws_file, $out_ws_folder, $task_exit, $qa_success, $elap), "\n";
}

if (0)
{
#
# Basenames only.
#
    for my $x (@out)
    {
	for my $col (4, 5, 7)
	{
	    $x->[$col] = basename($x->[$col]);
	}
	$x->[2] =~ s/([A-Z][a-z])/ \1/g;
	$x->[2] =~ s/([A-Z][a-z])/ \1/g;
    }
}

my @hdrs = ("Tag", "Container",  "App", "Task ID", "Input",  "FS Dir",  "Out File", "Out Folder",
	    "Task Exit", "QA Status", "Elapsed", "Hostname", "Output", "Max RSS");

print $out_fh join("\t", @hdrs), "\n";
print $out_fh join("\t", @$_), "\n" foreach @out;


if (0 && $opt->html_file)
{
    open(H, ">", $opt->html_file) or die "Cannot write " . $opt->html_file . ": $!\n";
    my $qt = HTML::QuickTable->new(header => 0, labels => 1, table => { border => 1 });

    my @dat = map { [ @$_[2,3,4,8,9,10, 11,12]  ]} (\@hdrs, @out);

    print H $qt->render(\@dat);
    close(H);
    
}

my $html_out;
if ($opt->html_file)
{
    $html_out = $opt->html_file;
}
elsif ($opt->html_dir)
{
    $html_out = $opt->html_dir . "/" . basename($input_file) . ".html";
}

if ($html_out)
{
    open(H, ">", $html_out) or die "Cannot write " . $html_out . ": $!\n";
    my $table = HTML::Table->new(-border => 1, -evenrowclass => 'even', -oddrowclass => 'odd', -padding => 2);

    my @dat = map { $_->[4] = basename($_->[4]); [ @$_[2,3,4,8,9,10,11,12,13]  ]} (\@hdrs, @out);

    for my $d (@dat)
    {
	my $elap = $d->[5];

	if ($elap =~ /^\d+$/)
	{
	    my $min = int($elap / 60);
	    my $sec = $elap % 60;
	    $d->[5] = sprintf("%4d:%02d", $min, $sec);
	}
	
	my $r = $table->addRow(@$d);

	my $stat = $d->[4];
	if ($stat eq 'OK')
	{
	    $table->setCellBGColor($r, 5, 'lightgreen');
	}
	elsif ($stat eq 'FAIL')
	{
	    $table->setCellBGColor($r, 5, 'pink');
	}
    }
    $table->setColAlign(4, 'center');
    $table->setColAlign(5, 'center');
    $table->setColAlign(6, 'right');

    $table->setRowHead(1);

    print H $table->getTable;
    close(H);
    
}
