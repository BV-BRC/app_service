
#
# Resubmit a job's load files for indexing.
#

use strict;
use P3AuthToken;
use P3DataAPI;
use File::Temp;
use File::Basename;
use Bio::KBase::AppService::SchedulerDB;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::AppConfig qw(data_api_url);
use File::Slurp;
use Getopt::Long::Descriptive;
use Data::Dumper;
use JSON::XS;
use IPC::Run;

my($opt, $usage) = describe_options("%c %o jobid...",
				    ["check-genome-sequences" => "Check for missing genome sequences and only reload those if they are missing"],
				    ["help|h" => "Show this help message"]);

print($usage->text), exit 0 if $opt->help;
print($usage->text), exit 1 if @ARGV == 0;

my @jobs = @ARGV;

my $db = Bio::KBase::AppService::SchedulerDB->new;
my $ws = Bio::P3::Workspace::WorkspaceClientExt->new;
#my $token = P3AuthToken->new;

my @conds;
my @params;

for my $id (@jobs)
{
    if ($id !~ /^\d+$/)
    {
	die "Invalid job id $id\n";
    }
}
my $vals = join(", ", @jobs);

push(@conds, "t.id IN ($vals)");

my $cond = join(" AND ", map { "($_)" } @conds);

my $qry = qq(SELECT t.id, t.output_path, t.output_file, t.application_id, tt.token
	     FROM Task t JOIN TaskToken tt ON t.id = tt.task_id
	     WHERE $cond);


my $res = $db->dbh->selectall_arrayref($qry, undef, @params);

for my $ent (@$res)
{
    my($job_id, $output_path, $output_file, $app_id, $token) = @$ent;

    if ($app_id eq 'ComprehensiveGenomeAnalysis')
    {
	$output_path .= "/.$output_file";
	$output_file = "annotation";
    }

#    print "Would resubmit $output_path $output_file $token\n";
#    next;
    
    resubmit_load_files($job_id, $output_path, $output_file, $app_id, $token);
}

sub resubmit_load_files
{
    my($job_id, $output_path, $output_file, $app_id, $token) = @_;

    my $temp = File::Temp->newdir(CLEANUP => 1);
    my $genome_url = data_api_url . "/indexer/genome";
    # print "temp=$temp\n";

    my $path = "$output_path/.$output_file/load_files";
    print "$path\n";
    my $res = $ws->ls({ paths => [$path], adminmode => 1 });
    my @opts;
    push(@opts, "-H", "Authorization: " . $token);
    push(@opts, "-H", "Content-Type: multipart/form-data");

    my @seq_files;
    for my $ent (@{$res->{$path}})
    {
	my($file, $type, $path) = @$ent;
	next unless $type eq 'json';
	my $dest = "$temp/$file";

	my $key = basename($file, ".json");

	my $x = $ws->download_file("$path$file", $dest, 1, $token, { admin => 1 });

	if ($opt->check_genome_sequences && $key eq 'genome_sequence')
	{
	    #
	    # Check data api to see if this genome sequence exists. If it does, we're OK so
	    # skip this genome.
	    #
	    my $dat = decode_json(scalar read_file($dest));
	    if (ref($dat) ne 'ARRAY')
	    {
		die "Error reading $dest - type is " . ref($dat) . " instead of ARRAY\n";
	    }
	    my $ent = $dat->[0];
	    my $gid = $ent->{genome_id};
	    if ($gid !~ /^\d+\.\d+$/)
	    {
		die "Invalid genome id '$gid' in data\n";
	    }
	    my $api = P3DataAPI->new(data_api_url, $token);
	    my @res = $api->query('genome_sequence', ['eq', 'genome_id', $gid], ['select', 'sequence_id']);
	    my $n_in_seqs = @$dat;
	    my $n_in_db = @res;
	    if ($n_in_seqs > 0 && $n_in_db == $n_in_seqs)
	    {
		print "$gid sequences are correct\n";
		return;
	    }
	    else
	    {
		print "Need to reload sequences for $gid\n";
		@seq_files = ("-F", "$key=\@$dest");

		#
		# Need to have the genome too for the indexer to work properly.
		#
		my $file = "genome.json";
		my $dest = "$temp/$file";
		$ws->download_file("$path/$file", $dest, 1, $token, { admin => 1 });
		push @seq_files, "-F", "genome=\@$dest";
		
		last;
	    }
	}
	push @seq_files, "-F", "$key=\@$dest";
    }

    push(@opts, @seq_files);
    push(@opts, $genome_url);
#    die Dumper(@opts);

#curl -H "Authorization: AUTHORIZATION_TOKEN_HERE" -H "Content-Type: multipart/form-data" -F "genome=@genome.json" -F "genome_feature=@genome_feature_patric.json" -F "genome_feature=@genome_feature_refseq.json" -F "genome_feature=@genome_feature_brc1.json" -F "genome_sequence=@genome_sequence.json" -F "pathway=@pathway.json" -F "sp_gene=@sp_gene.json"  

    my($stdout, $stderr);
    
    my $ok = IPC::Run::run(["curl", @opts], '>', \$stdout);
    if (!$ok)
    {
	warn "Error $? invoking curl @opts\n";
    }

    my $json = JSON::XS->new->allow_nonref;
    my $data = $json->decode($stdout);

    my $queue_id = $data->{id};

    print "Submitted indexing job $queue_id\n";
}
