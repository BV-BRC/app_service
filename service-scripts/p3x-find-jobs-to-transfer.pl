#
# Given a date (of last insertion of a genome), find the set of genomes
# that need to be loaded. Use the scheduler DB to find the set of users who
# submitted jobs and the related task ids.
#
# We can efficiently find the load_files folders that hold the data that
# is to be inserted into the database using that information.

use strict;
use Data::Dumper;
use DateTime;
use DateTime::Format::DateParse;
use P3DataAPI;
use File::Slurp;
use File::Path qw(make_path);
use LWP::UserAgent;
use P3ClientUA;
use JSON::XS;
use Config::Simple;
use MongoDB;
use Bio::P3::Workspace::WorkspaceClientExt;
use Getopt::Long::Descriptive;
use POSIX;

my($opt, $usage) = describe_options("%c %o cfg-file start-time output-dir",
				    ['skip-user=s@' => "Skip this user", { default => [] }],
				    ['restart' => "Try to restart using the state from the output directory"],
				    ["help|h" => "Show this help message"]);

print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 3;

my $cfg_file = shift;
my $start = shift;
my $out_dir = shift;

my $now = strftime("%Y-%m-%d-%H-%M-%S", localtime);

my @restart_data;
my %restart_seen;

if ($opt->restart)
{
    for my $fi (<$out_dir/file_info*txt>)
    {
	if (open(F, "<", $fi))
	{
	    while (<F>)
	    {
		chomp;
		my $f = [split(/\t/)];
		if (@$f == 4 && $f->[3] =~ /\.json$/)
		{
		    push(@restart_data, $f);
		    $restart_seen{$f->[3]} = $f;
		}
	    }
	    close(F);
	}
	else
	{
	    die "Cannot restart, cannot open $fi: $!";
	}
    }
    @restart_data or die "Cannnot restart, no previous data seen";
    if (-f "$out_dir/file_info.txt")
    {
	rename("$out_dir/file_info.txt", "$out_dir/file_info.$now.txt") or die "Cannot rename $out_dir/file_info.txt $out_dir/file_info.$now.txt: $!";
    }
}

my %skip_user = map { $_ => 1 } @{$opt->skip_user};

make_path($out_dir);
open(OUT, ">", "$out_dir/file_info.txt") or die "Cannot write $out_dir/file_info.txt: $!";
open(GLIST, ">", "$out_dir/genomes.txt") or die "Cannot write $out_dir/genomes.txt: $!";
open(MISSINGLIST, ">", "$out_dir/genomes.missing.txt") or die "Cannot write $out_dir/genomes.missing.txt: $!";

my $start_dt = DateTime::Format::DateParse->parse_datetime($start);
my $adj_start_dt = $start_dt->clone();
$adj_start_dt->subtract(days => 1 );


print "Starting from $start_dt adj $adj_start_dt\n";

my $api = P3DataAPI->new;
my $ua = P3ClientUA::new_ua();
my $ws = Bio::P3::Workspace::WorkspaceClientExt->new;

my $cfg = Config::Simple->new;
$cfg->read($cfg_file);
my %cfg = $cfg->vars;

my $mongo = MongoDB::MongoClient->new(host => $cfg{'Workspace.mongodb-host'},
				      port => $cfg{'Workspace.mongodb-port'} // 27017,
				      db_name => $cfg{'Workspace.mongodb-database'},
				      username => $cfg{'Workspace.mongodb-user'},
				      password => $cfg{'Workspace.mongodb-pwd'});

my $db = $mongo->get_database($cfg{'Workspace.mongodb-database'});
my $col = $db->get_collection("objects");

my $res = $ua->post("http://cherry.mcs.anl.gov:7000/solr/genome/select",
		    Accept => "application/json",
		    Content => qq(q=date_inserted:["${start_dt}Z" TO NOW]&rows=1000000&fl=genome_id,owner,date_inserted));

if (!$res->is_success)
{
    die "Qury failed " . $res->status_line . " " . $res->content;
}

my $data = decode_json($res->content);

my $gdata = $data->{response}->{docs};

$ENV{P3_FORCE_ADMIN} = 1;

my @genomes = map { $_->{genome_id} } @$gdata;
my %genomes = map { $_ => 1 } @genomes;
my %users = map { $_->{owner} => 1 } @$gdata;

#
# load workspace cache
#
my %wsname;
my $cur = $db->get_collection("workspaces")->find({});
while (my $doc = $cur->next)
{
    $wsname{$doc->{uuid}} = $doc->{name};
}

my @names = qw(genome_sequence genome_feature feature_sequence pathway subsystem sp_gene genome_amr);
for my $user (sort keys %users)
{
    next if $skip_user{$user};
    print "Search $user $adj_start_dt\n";
    my $cur = $col->find({creation_date => { '$gt' => $adj_start_dt . "Z" }, name => "load_files", owner => $user});
    while (my $doc = $cur->next)
    {
	my $base = "/$doc->{owner}/$wsname{$doc->{workspace_uuid}}/$doc->{path}/$doc->{name}";

	my $gid;
	my $dir;
	
	my $path = "$base/genome.json";

	if (my $rec = $restart_seen{$path})
	{
	    my($gid, $name, $user, $path) = @$rec;
	    print "Skip $gid $path\n";
	    delete $genomes{$gid};
	    next;
	}

	my $genome = eval { $ws->download_file_to_string($path); };
	if (!$genome)
	{
	    warn "Failed to download $path: $@\n";
	    next;
	}

	my $obj = eval {  decode_json($genome); };
	if (!$obj)
	{
	    warn "Failed to parse $path: $@\n";
	    next;
	}
	$gid = $obj->[0]->{genome_id};
	$dir = "$out_dir/$gid";
	make_path($dir);
	
	next unless delete $genomes{$gid};
	    
	print OUT join("\t", $gid, $obj->[0]->{genome_name}, $user, $path), "\n";
	write_file("$dir/genome.json", $genome);
	my @pairs;
	for my $which (@names)
	{
	    my $path = "$base/$which.json";
	    open(my $fh, ">", "$dir/$which.json") or die "Cannot write $out_dir/$which.json: $!";
	    push(@pairs, [$path, $fh]);
	}
	$ws->copy_files_to_handles(1, undef, \@pairs);
    }
}

close(OUT);
#print join(" ", sort keys %genomes), "\n";

print GLIST "$_\n" foreach sort @genomes;
close(GLIST);

print MISSINGLIST "$_\n" foreach sort keys %genomes;
close(MISSINGLIST);

# db.objects.find({"creation_date": { $gt: "2023-04-15T13:00:04.137Z"}, "name": "load_files", "owner": "BVBRC@patricbrc.org"})


