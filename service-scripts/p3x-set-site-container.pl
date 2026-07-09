=head1 NAME

    p3x-set-site-container - set the default container for a site type

=head1 SYNOPSIS

    p3x-set-site-container [OPTION] site-type-or-domain container-id

=head1 DESCRIPTION

Sets the default container ID for sites in the SiteDefaultContainer table.

The first argument selects the sites to update. It may be either:

=over 4

=item * a site_type (original behavior), which updates all sites of that type; or

=item * a domain matching the host part of a site's base_url. A domain selector
matches a site whose base_url host is exactly the selector or a subdomain of it,
so C<maage-brc.org> matches both C<www.maage-brc.org> and C<dev.maage-brc.org>,
while C<dev.maage-brc.org> matches only that site.

=back

If the selector matches a known site_type it is treated as a site_type;
otherwise it is treated as a domain.

The container ID must exist in the Container table.

=cut

use strict;
use Data::Dumper;
use Bio::KBase::AppService::SchedulerDB;

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o site-type-or-domain container-id",
				    ["list|l" => "List all site default containers"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;

my $db = Bio::KBase::AppService::SchedulerDB->new();

if ($opt->list)
{
    my $res = $db->dbh->selectall_arrayref(
	qq(SELECT sdc.base_url, sdc.site_type, sdc.default_container_id, c.filename, sdc.last_modified
	   FROM SiteDefaultContainer sdc
	   LEFT JOIN Container c ON sdc.default_container_id = c.id
	   ORDER BY sdc.site_type, sdc.base_url),
	{ Slice => {} }
    );

    if (@$res == 0)
    {
	print "No site default containers configured.\n";
    }
    else
    {
	printf "%-12s %-30s %-25s %s\n", "Site Type", "Base URL", "Container ID", "Filename";
	printf "%-12s %-30s %-25s %s\n", "-" x 12, "-" x 30, "-" x 25, "-" x 25;
	for my $row (@$res)
	{
	    printf "%-12s %-30s %-25s %s\n",
		$row->{site_type} // "(none)",
		$row->{base_url},
		$row->{default_container_id} // "(none)",
		$row->{filename} // "";
	}
    }
    exit 0;
}

die($usage->text) if @ARGV != 2;

my $selector = shift;
my $container_id = shift;

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
# The selector may be either a site_type (original behavior) or a domain
# matching the host part of a base_url. We try site_type first for backward
# compatibility, then fall back to domain matching.
#
my $valid_site_types = $db->dbh->selectcol_arrayref(
    qq(SELECT DISTINCT site_type FROM SiteDefaultContainer WHERE site_type IS NOT NULL)
);
my %valid = map { $_ => 1 } @$valid_site_types;

my $match_desc;     # human-readable description of what matched
my @current;        # rows ({base_url, default_container_id}) to update
my $update_sql;
my @update_params;

if ($valid{$selector})
{
    #
    # Site-type match: update all sites of this type.
    #
    $match_desc = "site_type '$selector'";
    @current = @{ $db->dbh->selectall_arrayref(
	qq(SELECT base_url, default_container_id
	   FROM SiteDefaultContainer
	   WHERE site_type = ?),
	{ Slice => {} }, $selector) };

    $update_sql = qq(UPDATE SiteDefaultContainer
		     SET default_container_id = ?, last_modified = CURRENT_TIMESTAMP
		     WHERE site_type = ?);
    @update_params = ($container_id, $selector);
}
else
{
    #
    # Domain match against the host part of base_url. A site matches when its
    # host equals the selector or is a subdomain of it.
    #
    my $domain = normalize_domain($selector);

    my $all = $db->dbh->selectall_arrayref(
	qq(SELECT base_url, default_container_id
	   FROM SiteDefaultContainer),
	{ Slice => {} });

    for my $row (@$all)
    {
	my $host = host_of($row->{base_url});
	next unless defined $host;
	if ($host eq $domain || $host =~ /\.\Q$domain\E$/)
	{
	    push @current, $row;
	}
    }

    if (@current == 0)
    {
	my $valid_list = join(", ", sort @$valid_site_types);
	my %seen;
	my @domains = sort grep { defined && !$seen{$_}++ } map { host_of($_->{base_url}) } @$all;
	die "'$selector' does not match any site_type or base_url domain.\n" .
	    "Valid site_type values are: $valid_list\n" .
	    "Known site domains are: " . join(", ", @domains) . "\n";
    }

    $match_desc = "domain '$domain'";
    my @urls = map { $_->{base_url} } @current;
    my $placeholders = join(",", ("?") x @urls);
    $update_sql = qq(UPDATE SiteDefaultContainer
		     SET default_container_id = ?, last_modified = CURRENT_TIMESTAMP
		     WHERE base_url IN ($placeholders));
    @update_params = ($container_id, @urls);
}

#
# Apply the update.
#
my $res = $db->dbh->do($update_sql, undef, @update_params);

print "Updated $res site(s) matching $match_desc to container '$container_id':\n";
for my $row (@current)
{
    my $old = $row->{default_container_id} // "(none)";
    print "  $row->{base_url}: $old -> $container_id\n";
}

#
# Extract the lowercased host part from a base_url (or a bare domain), stripping
# any scheme, path, and port. Returns undef for an empty result.
#
sub host_of
{
    my ($url) = @_;
    return undef unless defined $url;
    my $h = lc $url;
    $h =~ s/^\s+|\s+$//g;
    $h =~ s{^[a-z][a-z0-9+.-]*://}{};   # strip scheme
    $h =~ s{[/:].*$}{};                 # strip path / port
    return $h eq '' ? undef : $h;
}

sub normalize_domain
{
    my ($d) = @_;
    my $h = host_of($d);
    return defined $h ? $h : lc $d;
}
