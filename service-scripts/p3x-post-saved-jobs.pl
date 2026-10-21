#
# Post jobs from the transfer folder to the given Solr URL
#
# Perform a bulk pre-query to ensure the jobs were not already loaded.
#
# We log completed uploads to transfer-dir/completed 
# 

use strict;
use IO::Handle;
use Fcntl qw(:flock SEEK_END SEEK_SET);
use Data::Dumper;
use LWP::UserAgent;
use P3ClientUA;
use JSON::XS;
use File::Slurp;

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o transfer-dir",
				    ["genome=s" => "Only load this genome"],
				    ["one-shot" => "Only transfer one genome"],
				    ["help|h" => "Show this help message."]);

print($usage->text), exit(0) if $opt->help;
die($usage->text) unless @ARGV == 1;

my $transfer_dir = shift;

-d $transfer_dir or die "Transfer directory $transfer_dir does not exist\n";
my $solr_url = "http://balsam.cels.anl.gov:15183";

my $ua = P3ClientUA::new_ua();
my @cores = qw(genome genome_sequence genome_feature feature_sequence pathway subsystem sp_gene genome_amr);

open(LOG, "+>>", "$transfer_dir/completed") or die "Cannot open $transfer_dir/completed: $!";
seek(LOG, 0, SEEK_SET) or die "cannot seek: $!";
my %seen;
while (<LOG>)
{
    chomp;
    if (/^(\d+\.\d+)/)
    {
	$seen{$1}++;
    }
    else
    {
	die "Invalid line $. in $transfer_dir/completed\n";
    }
}

seek(LOG, 0, SEEK_END) or die "cannot seek: $!";
LOG->autoflush(1);

if ($opt->genome)
{
    load_genome($opt->genome);
}


sub load_genome
{
    my($genome) = @_;

    if ($seen{$genome})
    {
	print "$genome already loaded\n";
	return;
    }

    my $res = query($genome);

    if (@$res > 0)
    {
	print "Already have $genome: " . Dumper($res);
	return;
    }

    my @to_post;
    for my $core (@cores)
    {
	my $file = "$transfer_dir/$genome/$core.json";
	if (!-f $file)
	{
	    die "Transfer file missing: $file\n";
	}
	push(@to_post, [$core, $file]);
    }

    for my $ent (@to_post)
    {
	my($core, $file) = @$ent;

	my $data = read_file($file);
	$data or die "Cannot read $file: $!";
	
	my $res = $ua->post("$solr_url/solr/$core/update?wt=json&overwrite=true&commit=false",
			    "Content-type", "application/json",
			    Content => $data);
	$res->is_success or die "Failure to post $core $file: " . $res->status_line . " " . $res->content;
	print "Posted: " . $res->content;
	my $obj = eval { decode_json($res->content); };
	$obj or die "Error parsing solr output " . $res->content;
	if ($obj->{response_header} && $obj->{response_header}->{status} != 0)
	{
	    die "Nonzero status from post: " . $res->content;
	}
    }

    print "Load $genome\n";
    print LOG "$genome\tloaded\n";
    exit;
    
}


sub query
{
    my($genome) = @_;

    my $res = $ua->post("$solr_url/solr/genome/select",
			"Accept", "application/json",
			"Content", "q=genome_id:$genome&fl=genome_id,genome_name,date_inserted");
    $res->is_success || die "Failed query for $genome";

    my $obj = eval { decode_json($res->content); };
    $obj->{responseHeader}->{status} == 0 or die "Query for $genome failed: " . $res->content;
    return $obj->{response}->{docs};
}
