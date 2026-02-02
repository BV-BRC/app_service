#
# Load app specs to scheduler cache directory and into the database
#
# These are loaded from the given container.
#

use strict;
use Data::Dumper;
use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::Scheduler;
use Getopt::Long::Descriptive;
use File::Temp;
use IPC::Run;
use JSON::XS;
use File::Slurp;
use File::Copy::Recursive qw(dircopy);

my($opt, $usage) = describe_options("%c %o container.sif [cache-dir]",
				    ["help|h" => "Show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 1 && @ARGV != 2;

my $container = shift;
my $cache_dir = shift;

-f $container or die "Container $container not found\n";
if ($cache_dir)
{
    -d $cache_dir or die "Cache directory $cache_dir not found\n";
}

my $tmpdir = File::Temp->newdir();

my $ok = IPC::Run::run(["singularity", "exec", $container,
			"tar", "-c", "-f", "-", "-C", "/opt/p3/deployment/services/app_service", "app_specs", "-C", "/.singularity.d", "labels.json"],
		       "|",
		       ["tar", "-C", $tmpdir, "-x", "-f", "-"]);
$ok or die "Error loading data from container $container\n";


my $labels = decode_json(scalar read_file("$tmpdir/labels.json"));

my $release = $labels->{release};

print STDERR "Loading release $release\n";

my $release_name = "release-$release";
if ($cache_dir)
{
    my $release_dir = "$cache_dir/$release_name";
    -d $release_dir and die "Release $release already loaded in $release_dir\n";
    
    dircopy($tmpdir, $release_dir);
}
system("ls -lR $tmpdir/app_specs");
my $specs = Bio::KBase::AppService::AppSpecs->new("$tmpdir/app_specs");
print STDERR "Loading specs:\n";
print "\t$_->{id}\n" foreach $specs->enumerate;

my $sched = Bio::KBase::AppService::Scheduler->new(specs => $specs);
$sched->load_apps();

#
# Update the "latest" symlink
#

if ($cache_dir)
{
    my $latest = "$cache_dir/latest";
    unlink($latest);
    symlink($release_name, "$cache_dir/latest");
}
