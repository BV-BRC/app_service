=head1 NAME

    p3x-add-container - add a new container image to the scheduler database

=head1 SYNOPSIS

    p3x-add-container [OPTION] container-id

=head1 DESCRIPTION

Adds a new container image ID to the Container table in the scheduler database.

The container ID must not already exist in the database. The image filename
defaults to the container ID with a ".sif" suffix. The existence of the
image file in /vol/patric3/production/containers is verified before adding.

=cut

use strict;
use Data::Dumper;
use Bio::KBase::AppService::SchedulerDB;

use Getopt::Long::Descriptive;

my $default_container_dir = "/vol/patric3/production/containers";

my($opt, $usage) = describe_options("%c %o container-id",
				    ["filename|f=s" => "Override the default filename (container-id.sif)"],
				    ["container-dir|d=s" => "Container directory (default: $default_container_dir)",
				     { default => $default_container_dir }],
				    ["force" => "Add even if file does not exist (not recommended)"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 1;

my $container_id = shift;

#
# Validate container ID format - should be reasonable identifier
#
if ($container_id !~ /^[\w.-]+$/)
{
    die "Invalid container ID '$container_id': must contain only alphanumeric characters, dots, underscores, and hyphens\n";
}

#
# Determine filename
#
my $filename = $opt->filename // "$container_id.sif";

#
# Verify image file exists
#
my $container_path = $opt->container_dir . "/" . $filename;
if (!-f $container_path)
{
    if ($opt->force)
    {
	warn "Warning: Container image file $container_path does not exist (proceeding due to --force)\n";
    }
    else
    {
	die "Container image file $container_path does not exist\n";
    }
}

my $db = Bio::KBase::AppService::SchedulerDB->new();

#
# Check if container ID already exists
#
my $existing = $db->dbh->selectrow_arrayref(
    qq(SELECT id, filename FROM Container WHERE id = ?),
    undef, $container_id
);

if ($existing)
{
    die "Container ID '$container_id' already exists in database with filename '$existing->[1]'\n";
}

#
# Insert the new container record
#
my $res = $db->dbh->do(
    qq(INSERT INTO Container (id, filename) VALUES (?, ?)),
    undef, $container_id, $filename
);

if ($res != 1)
{
    die "Failed to insert container record\n";
}

print "Added container '$container_id' with filename '$filename'\n";
