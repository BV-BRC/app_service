=head1 NAME

    p3x-show-container-config - show container configuration status

=head1 SYNOPSIS

    p3x-show-container-config [OPTION]

=head1 DESCRIPTION

Displays the status of all container-related tables in the scheduler database:

=over 4

=item * Container - all registered container images

=item * ApplicationDefaultContainer - per-application container overrides

=item * SiteDefaultContainer - per-site (base_url) container overrides

=item * Cluster - cluster default containers

=back

=cut

use strict;
use Data::Dumper;
use Bio::KBase::AppService::SchedulerDB;

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["containers|c" => "Show only Container table"],
				    ["apps|a" => "Show only ApplicationDefaultContainer table"],
				    ["sites|s" => "Show only SiteDefaultContainer table"],
				    ["clusters|C" => "Show only Cluster table"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;

my $db = Bio::KBase::AppService::SchedulerDB->new();

#
# If no specific table requested, show all
#
my $show_all = !($opt->containers || $opt->apps || $opt->sites || $opt->clusters);

#
# Container table
#
if ($show_all || $opt->containers)
{
    print "=" x 80, "\n";
    print "CONTAINERS (Container table - last 5 by date)\n";
    print "=" x 80, "\n\n";

    my $res = $db->dbh->selectall_arrayref(
	qq(SELECT id, filename, creation_date FROM Container
	   ORDER BY creation_date DESC
	   LIMIT 5),
	{ Slice => {} }
    );

    if (@$res == 0)
    {
	print "  No containers registered.\n";
    }
    else
    {
	printf "  %-40s %-40s %s\n", "Container ID", "Filename", "Created";
	printf "  %-40s %-40s %s\n", "-" x 40, "-" x 40, "-" x 20;
	for my $row (@$res)
	{
	    printf "  %-40s %-40s %s\n",
		$row->{id},
		$row->{filename} // "(none)",
		$row->{creation_date} // "";
	}
    }
    print "\n";
}

#
# ApplicationDefaultContainer table
#
if ($show_all || $opt->apps)
{
    print "=" x 80, "\n";
    print "APPLICATION DEFAULT CONTAINERS (ApplicationDefaultContainer table)\n";
    print "=" x 80, "\n\n";

    my $res = $db->dbh->selectall_arrayref(
	qq(SELECT adc.application_id, adc.site_type, adc.default_container_id, c.filename
	   FROM ApplicationDefaultContainer adc
	   LEFT JOIN Container c ON adc.default_container_id = c.id
	   ORDER BY adc.application_id, adc.site_type),
	{ Slice => {} }
    );

    if (@$res == 0)
    {
	print "  No application default containers configured.\n";
    }
    else
    {
	printf "  %-30s %-12s %-30s %s\n", "Application", "Site Type", "Container ID", "Filename";
	printf "  %-30s %-12s %-30s %s\n", "-" x 30, "-" x 12, "-" x 30, "-" x 25;
	for my $row (@$res)
	{
	    printf "  %-30s %-12s %-30s %s\n",
		$row->{application_id},
		$row->{site_type} eq '' ? "(global)" : $row->{site_type},
		$row->{default_container_id} // "(none)",
		$row->{filename} // "";
	}
    }
    print "\n";
}

#
# SiteDefaultContainer table
#
if ($show_all || $opt->sites)
{
    print "=" x 80, "\n";
    print "SITE DEFAULT CONTAINERS (SiteDefaultContainer table)\n";
    print "=" x 80, "\n\n";

    my $res = $db->dbh->selectall_arrayref(
	qq(SELECT sdc.base_url, sdc.default_container_id, c.filename, sdc.last_modified
	   FROM SiteDefaultContainer sdc
	   LEFT JOIN Container c ON sdc.default_container_id = c.id
	   ORDER BY sdc.base_url),
	{ Slice => {} }
    );

    if (@$res == 0)
    {
	print "  No site default containers configured.\n";
    }
    else
    {
	printf "  %-50s %-30s %s\n", "Base URL", "Container ID", "Last Modified";
	printf "  %-50s %-30s %s\n", "-" x 50, "-" x 30, "-" x 20;
	for my $row (@$res)
	{
	    printf "  %-50s %-30s %s\n",
		$row->{base_url},
		$row->{default_container_id} // "(none)",
		$row->{last_modified} // "";
	}
    }
    print "\n";
}

#
# Cluster table (container-related fields only)
#
if ($show_all || $opt->clusters)
{
    print "=" x 80, "\n";
    print "CLUSTER DEFAULT CONTAINERS (Cluster table)\n";
    print "=" x 80, "\n\n";

    my $res = $db->dbh->selectall_arrayref(
	qq(SELECT cl.id, cl.name, cl.default_container_id, c.filename,
	          cl.container_repo_url, cl.container_cache_dir,
	          cl.default_data_container_id, dc.name as data_container_name
	   FROM Cluster cl
	   LEFT JOIN Container c ON cl.default_container_id = c.id
	   LEFT JOIN DataContainer dc ON cl.default_data_container_id = dc.id
	   ORDER BY cl.id),
	{ Slice => {} }
    );

    if (@$res == 0)
    {
	print "  No clusters configured.\n";
    }
    else
    {
	for my $row (@$res)
	{
	    print "  Cluster: $row->{id}";
	    print " ($row->{name})" if $row->{name};
	    print "\n";

	    printf "    %-30s %s\n", "Default Container:",
		$row->{default_container_id} // "(none)";
	    printf "    %-30s %s\n", "Container Filename:",
		$row->{filename} // "(none)" if $row->{default_container_id};
	    printf "    %-30s %s\n", "Container Repo URL:",
		$row->{container_repo_url} // "(none)";
	    printf "    %-30s %s\n", "Container Cache Dir:",
		$row->{container_cache_dir} // "(none)";
	    printf "    %-30s %s\n", "Default Data Container:",
		$row->{default_data_container_id} // "(none)";
	    printf "    %-30s %s\n", "Data Container Name:",
		$row->{data_container_name} // "(none)" if $row->{default_data_container_id};
	    print "\n";
	}
    }
}
