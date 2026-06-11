=head1 NAME

    p3x-set-app-container - set the default container for an application

=head1 SYNOPSIS

    p3x-set-app-container [OPTION] app-id container-id

=head1 DESCRIPTION

Sets or updates the default container ID for an application in the
ApplicationDefaultContainer table.

The container ID must exist in the Container table. If the application
already has a default container configured, it will be updated to the
new container ID.

Use --site-type to set a container override for a specific site type
(e.g., alpha, beta, prod). Without --site-type, sets the global default
for the application.

=cut

use strict;
use Data::Dumper;
use Bio::KBase::AppService::SchedulerDB;

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o app-id container-id",
				    ["site-type|s=s" => "Site type (e.g., alpha, beta, prod) for site-specific override"],
				    ["list|l" => "List all application default containers"],
				    ["remove|r" => "Remove the default container for the app (container-id not required)"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;

my $db = Bio::KBase::AppService::SchedulerDB->new();

if ($opt->list)
{
    my $res = $db->dbh->selectall_arrayref(
	qq(SELECT adc.application_id, adc.site_type, adc.default_container_id, c.filename
	   FROM ApplicationDefaultContainer adc
	   LEFT JOIN Container c ON adc.default_container_id = c.id
	   ORDER BY adc.application_id, adc.site_type),
	{ Slice => {} }
    );

    if (@$res == 0)
    {
	print "No application default containers configured.\n";
    }
    else
    {
	printf "%-35s %-12s %-35s %s\n", "Application", "Site Type", "Container ID", "Filename";
	printf "%-35s %-12s %-35s %s\n", "-" x 35, "-" x 12, "-" x 35, "-" x 30;
	for my $row (@$res)
	{
	    printf "%-35s %-12s %-35s %s\n",
		$row->{application_id},
		$row->{site_type} eq '' ? "(global)" : $row->{site_type},
		$row->{default_container_id} // "(none)",
		$row->{filename} // "";
	}
    }
    exit 0;
}

my $site_type = $opt->site_type // '';

if ($opt->remove)
{
    die($usage->text) if @ARGV != 1;
    my $app_id = shift;

    #
    # Validate site_type if specified
    #
    if ($site_type ne '')
    {
	my $valid_site_types = $db->dbh->selectcol_arrayref(
	    qq(SELECT DISTINCT site_type FROM SiteDefaultContainer WHERE site_type IS NOT NULL)
	);
	my %valid = map { $_ => 1 } @$valid_site_types;

	if (!$valid{$site_type})
	{
	    my $valid_list = join(", ", sort @$valid_site_types);
	    die "Invalid site_type '$site_type'.\n" .
		"Valid site_type values are: $valid_list\n";
	}
    }

    my $res = $db->dbh->do(
	qq(DELETE FROM ApplicationDefaultContainer WHERE application_id = ? AND site_type = ?),
	undef, $app_id, $site_type
    );

    if ($res == 0)
    {
	my $type_msg = $site_type ne '' ? " for site_type '$site_type'" : " (global)";
	print "No default container was configured for application '$app_id'$type_msg\n";
    }
    else
    {
	my $type_msg = $site_type ne '' ? " for site_type '$site_type'" : " (global)";
	print "Removed default container for application '$app_id'$type_msg\n";
    }
    exit 0;
}

die($usage->text) if @ARGV != 2;

my $app_id = shift;
my $container_id = shift;

#
# Validate site_type if specified (must exist in SiteDefaultContainer)
#
if ($site_type ne '')
{
    my $valid_site_types = $db->dbh->selectcol_arrayref(
	qq(SELECT DISTINCT site_type FROM SiteDefaultContainer WHERE site_type IS NOT NULL)
    );
    my %valid = map { $_ => 1 } @$valid_site_types;

    if (!$valid{$site_type})
    {
	my $valid_list = join(", ", sort @$valid_site_types);
	die "Invalid site_type '$site_type'.\n" .
	    "Valid site_type values are: $valid_list\n";
    }
}

#
# Verify the container ID exists in the Container table
#
my $container = $db->dbh->selectrow_arrayref(
    qq(SELECT id, filename FROM Container WHERE id = ?),
    undef, $container_id
);

if (!$container)
{
    die "Container ID '$container_id' does not exist in the Container table.\n" .
	"Use p3x-add-container to add it first.\n";
}

#
# Check if application already has a default container for this site_type
#
my $existing = $db->dbh->selectrow_arrayref(
    qq(SELECT application_id, site_type, default_container_id
       FROM ApplicationDefaultContainer
       WHERE application_id = ? AND site_type = ?),
    undef, $app_id, $site_type
);

my $type_msg = $site_type ne '' ? " for site_type '$site_type'" : " (global)";

if ($existing)
{
    #
    # Update existing record
    #
    my $old_container = $existing->[2];

    if ($old_container eq $container_id)
    {
	print "Application '$app_id'$type_msg already has container '$container_id' as default.\n";
	exit 0;
    }

    my $res;
    $res = $db->dbh->do(
	qq(UPDATE ApplicationDefaultContainer SET default_container_id = ?
	   WHERE application_id = ? AND site_type = ?),
	undef, $container_id, $app_id, $site_type
    );

    if ($res != 1)
    {
	die "Failed to update default container for application\n";
    }

    print "Updated application '$app_id'$type_msg default container from '$old_container' to '$container_id'\n";
}
else
{
    #
    # Insert new record
    #
    my $res = $db->dbh->do(
	qq(INSERT INTO ApplicationDefaultContainer (application_id, site_type, default_container_id)
	   VALUES (?, ?, ?)),
	undef, $app_id, $site_type, $container_id
    );

    if ($res != 1)
    {
	die "Failed to insert default container for application\n";
    }

    print "Set application '$app_id'$type_msg default container to '$container_id'\n";
}
