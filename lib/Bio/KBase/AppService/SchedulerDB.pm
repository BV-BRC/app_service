package Bio::KBase::AppService::SchedulerDB;

use strict;
use 5.010;
use DBI;
use AnyEvent;
use AnyEvent::DBI::MySQL;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name
					 app_directory app_service_url);
use Scope::Guard;
use JSON::XS;
use base 'Class::Accessor';
use Data::Dumper;

#
# Simple wrapper class around the scheduler DB. Used when performance
# is important.
#

__PACKAGE__->mk_accessors(qw(dbh json dsn user pass queued_status));

sub new
{
    my($class) = @_;

    my $port = sched_db_port // 3306;

    my $dsn = "dbi:mysql:" . sched_db_name . ";host=" . sched_db_host . ";port=$port";
    my $self = {
	user => sched_db_user,
	pass => sched_db_pass,
	dsn => $dsn,
	json => JSON::XS->new->pretty(1)->canonical(1),
	state_code_cache => undef,
    };
    return bless $self, $class;
}

sub dbh
{
    my($self) = @_;
    return $self->{dbh} if $self->{dbh};
    
    my $dbh =  $self->{dbh} = DBI->connect($self->dsn, $self->user, $self->pass,
				       { mysql_ssl => 1, AutoCommit => 1, RaiseError => 1 });
    $dbh or die "Cannot connect to database: " . $DBI::errstr;
    $dbh->do(qq(SET time_zone = "+00:00"));
    return $dbh;
}

#
# Create an Async handle if needed.
#
sub async_dbi
{
    my($self) = @_;
    # Do not cache. This lets us have multiple handles flowing.
    #return $self->{async} if $self->{async};

    print STDERR "asycn create\n";
    my $cv = AnyEvent->condvar;
    my $async;
    $async = new AnyEvent::DBI($self->dsn, $self->user, $self->pass,
				  PrintError => 0,
				  on_error => sub { print STDERR "ERROR on new @_\n"},
				  on_connect => sub {
				      my($dbh, $ok) = @_;
				      print STDERR "on conn  ok=$ok\n";
				      #
				      # Force timezone
				      #
				      $async->exec(qq(SET time_zone = "+00:00"), sub {
					  print STDERR "On conn\n";
					  $cv->send;
				      });
				  });
					       
    print STDERR "Wait for conn\n";
    $cv->wait;
    print STDERR "connected\n";
    #$self->{async} = $async;
    return $async;
}

sub async_mysql
{
    my($self) = @_;

    my $async = AnyEvent::DBI::MySQL->connect($self->dsn, $self->user, $self->pass);

    return $async;
}
*async = *async_mysql;

#
# Lazily load requirement for DBIx::Class and create the schema object.
#
sub schema
{
    my($self) = @_;
    return $self->{schema} if $self->{schema};

    require Bio::KBase::AppService::Schema;
    my $port = sched_db_port // 3306;

    my $extra = {
	on_connect_do => qq(SET time_zone = "+00:00"),
    };
    
    my $schema = Bio::KBase::AppService::Schema->connect($self->dsn, $self->user, $self->pass, undef, $extra);

    $schema or die "Cannot connect to database: " . Bio::KBase::AppService::Schema->errstr;

    $self->{schema} = $schema;
    return $schema;

}

sub begin_work
{
    my($self) = @_;
    $self->dbh->begin_work if $self->dbh->{AutoCommit};
}

sub commit
{
    my($self) = @_;
    $self->dbh->commit;
}

sub rollback
{
    my($self) = @_;
    $self->dbh->rollback;
}

sub create_task
{
    my($self, $token, $app_id, $monitor_url, $task_parameters, $start_parameters, $preflight, $app_spec) = @_;

    my $override_user = $start_parameters->{user_override};

    my $guard = Scope::Guard->new(sub {
	warn "create_task: rolling back transaction\n";
	$self->rollback();
    });

    $self->begin_work();

    #
    # If we were not provided an app spec, try to find one.
    #
    if (!$app_spec)
    {
	my $app = $self->find_app($app_id);
	$app_spec = $app->{spec};
    }
    
    my $user = $self->find_user($override_user // $token->user_id, $token);

    #
    # Create our task.
    #

    my $code = $self->state_code_id('queued');

    my $policy_data = {};

    #
    # Policy data. We merge keys from policy-related start parameters
    # and anything in the preflight policy data.
    #

    $policy_data->{$_} = $start_parameters->{$_} foreach grep { exists $start_parameters->{$_} } qw(reservation constraint);
    $policy_data->{$_} = $preflight->{policy_data}->{$_} foreach keys %{$preflight->{policy_data}};
    
    my $container_id = $self->determine_container_id_override($task_parameters, $start_parameters);
    my $data_container_id = $self->determine_data_container_id_override($task_parameters, $start_parameters);

    #
    # Annotate task parameters with preflight data; this allows the preflight to pass
    # configuration data to the scheduled invocation of the job (e.g. a choice to use bebop
    # for assembly, since this choice affects the number of CPUs allocated for the job).
    #
    $task_parameters->{_preflight} = $preflight;
    
    my $task = {
	owner => $user->{id},
	base_url => $start_parameters->{base_url},
	parent_task => $start_parameters->{parent_id},
	state_code => $code,
	application_id => $app_id,
	params => $self->json->encode($task_parameters),
	(ref($task_parameters) eq 'HASH' ?
	 (output_path => $task_parameters->{output_path},
	  output_file => $task_parameters->{output_file}) : ()),
	app_spec => $self->json->encode($app_spec),
	monitor_url => $monitor_url,
	req_memory => $preflight->{memory},
	req_cpu => $preflight->{cpu},
	req_runtime => $preflight->{runtime},
	req_policy_data => $self->json->encode($policy_data),
	req_is_control_task => ($preflight->{is_control_task} ? 1 : 0),
	user_metadata => $start_parameters->{user_metadata},    
	(defined($container_id) ? (container_id => $container_id) : ()),
	(defined($data_container_id) ? (data_container_id => $data_container_id) : ()),
	};

    my $fields = join(", ", keys %$task);
    my $qs = join(", ", map { "?" } keys %$task);
    my $res = $self->dbh->do(qq(INSERT INTO Task (submit_time, $fields) VALUES (CURRENT_TIMESTAMP(), $qs)), undef, values %$task);
    if ($res != 1)
    {
	die "Failed to insert task";
    }
    my $id = $self->dbh->last_insert_id(undef, undef, 'Task', 'id');

    $task->{id} = $id;

    $res = $self->dbh->do(qq(INSERT INTO TaskToken (task_id, token, expiration)
			     VALUES (?, ?, FROM_UNIXTIME(?))), undef,
			  $id, $token->token, $token->expiry);
    if ($res != 1)
    {
	die "Failed to insert TaskToken";
    }
    
    $guard->dismiss(1);
    $self->commit();
    return $task;
}

=head2 determine_container_id_override

Determine if the given task_params and start_params includes an explicit container_id override.

In order, examine

    $task_params->{container_id}
    $start_params->{container_id}

=cut

sub determine_container_id_override
{
    my($self, $task_params, $start_params) = @_;

    return $task_params->{container_id} // $start_params->{container_id};
}
    
=head2 determine_data_container_id_override

Determine if the given task_params and start_params includes an explicit data_container_id override.

In order, examine

    $task_params->{data_container_id}
    $start_params->{data_container_id}

=cut

sub determine_data_container_id_override
{
    my($self, $task_params, $start_params) = @_;

    return $task_params->{data_container_id} // $start_params->{data_container_id};
}
    
#
# For the given cluster, determine if there is a default container.
# If so return its ID and pathname
#
sub cluster_default_container
{
    my($self, $cluster_name) = @_;

    my $res = $self->dbh->selectrow_arrayref(qq(
						SELECT cl.container_repo_url, cl.default_container_id, cl.container_cache_dir, c.filename
						FROM Cluster cl JOIN Container c ON cl.default_container_id = c.id
						WHERE cl.id = ?), undef, $cluster_name);
    if (!$res || @$res == 0)
    {
	warn "No container found for cluster $cluster_name\n";
	return undef;
    }
    my($url, $container_id, $cache, $filename) = @$res;

    return ($url, $container_id, $cache, $filename);
}    

#
# Look up the given container id.
#
sub find_container
{
    my($self, $container_id) = @_;

    my $res = $self->dbh->selectrow_arrayref(qq(SELECT c.filename
						FROM Container c 
						WHERE c.id = ?), undef, $container_id);
    if (!$res || @$res == 0)
    {
	warn "No container found for id $container_id\n";
	return undef;
    }
    return $res->[0];
}    

sub find_user
{
    my($self, $userid) = @_;

    my($base, $domain) = $userid =~ /(.*)\@([^@]+)$/;
    if ($domain eq '')
    {
	$domain = 'rast.nmpdr.org';
	$userid = "$userid\@$domain";
    }

    my $res = $self->dbh->selectrow_hashref(qq(SELECT * FROM ServiceUser WHERE id = ?), undef, $userid);

    return $res if $res;

    my $res = $self->dbh->selectcol_arrayref(qq(SELECT id FROM Project WHERE userid_domain = ?), undef, $domain);
    if (@$res == 0)
    {
	die "Unknown user domain $domain\n";
    }
    my $proj_id = $res->[0];

    $self->dbh->do(qq(INSERT INTO ServiceUser (id, project_id) VALUES (?, ?)), undef, $userid, $proj_id);

    #
    # We used to have code that used the PATRIC user service to inflate the data.
    # It does not belong here; if we want fuller user data we should have a separate
    # offline thread to manage updates when needed.
    #
    # We also don't try to tell the cluster that there is a new user. When a job
    # is submitted we will get an error that hte usthe user is missing, so we
    # may use that to trigger a fuller update to the both the database and to
    # the cluster user configuration.
    #

    return { id => $userid, project_id => $proj_id };
}

=item B<find_app>

Find this app in the database. If it is not there, use the AppSpecs instance
to find the spec file in the filesystem. If that is not there, fail.

    $app = $sched->find_app($app_id)

We return an Application result object.

Assume that we are executing inside a transaction.

=cut

sub find_app
{
    my($self, $app_id, $specs) = @_;

    my $sth = $self->dbh->prepare(qq(SELECT * FROM Application WHERE id = ?));
    $sth->execute($app_id);
    my $obj = $sth->fetchrow_hashref();

    return $obj if $obj;

    if (!$specs)
    {
	die "App $app_id not in database and no specs were passed";
    }
    
    my $app = $specs->find($app_id);
    if (!$app)
    {
	die "Unable to find application '$app_id'";
    }

    my $spec = $self->json->encode($app);
    $self->dbh->do(qq(INSERT INTO Application (id, script, default_memory, default_cpu, spec)
		      VALUES (?, ?, ?, ?, ?)), undef,
		   $app_id,
		   $app->{script},
		   $app->{default_ram},
		   $app->{default_cpu},
		   $spec);
    
    return {
	id => $app_id,
	spec => $spec,
	default_cpu => $app->{default_cpu},
	default_memory => $app->{default_ram},
	script => $app->{script},
    };
}

sub query_tasks
{
    my($self, $user_id, $task_ids) = @_;

    my $id_list = join(", ", grep { /^\d+$/ } @$task_ids);
    return {} unless $id_list;

    my $sth = $self->dbh->prepare(qq(SELECT id, parent_task, application_id, params, owner, state_code,
				     if(submit_time = default(submit_time), "", submit_time) as submit_time,
				     if(start_time = default(start_time), "", start_time) as start_time,
				     if(finish_time = default(finish_time), "", finish_time) as finish_time,
				     IF(finish_time != DEFAULT(finish_time) AND start_time != DEFAULT(start_time), timediff(finish_time, start_time), '') as elapsed_time,
				     service_status,
				     'active' as storage_location

				     FROM Task JOIN TaskState ON state_code = code
					       WHERE id IN ($id_list)
				     UNION ALL
				     SELECT id, parent_task, application_id, params, owner, state_code,
				     if(submit_time = default(submit_time), "", submit_time) as submit_time,
				     if(start_time = default(start_time), "", start_time) as start_time,
				     if(finish_time = default(finish_time), "", finish_time) as finish_time,
				     IF(finish_time != DEFAULT(finish_time) AND start_time != DEFAULT(start_time), timediff(finish_time, start_time), '') as elapsed_time,
				     service_status,
				     'archive' as storage_location
				     FROM ArchivedTask JOIN TaskState ON state_code = code
					       WHERE id IN ($id_list)
				     
				       ORDER BY submit_time DESC));
    
    $sth->execute();
    my $ret = {};
    while (my $ent = $sth->fetchrow_hashref())
    {
	$ret->{$ent->{id}} = $self->format_task_for_service($ent);
    }

    return $ret;
}

=item B<query_task_summary>

Return a summary of the counts of the task types for the specified user.

=cut

sub query_task_summary
{
    my($self, $user_id) = @_;

    my $res = $self->dbh->selectall_arrayref(qq(SELECT COUNT(id) AS count, service_status
						FROM (SELECT id, ts.service_status
						      FROM Task t JOIN TaskState ts ON t.state_code = ts.code
						      WHERE owner = ?
						      UNION ALL
						      SELECT id, service_status
						      FROM ArchivedTask t JOIN TaskState ts ON t.state_code = ts.code
						      WHERE owner = ?) as t
						GROUP BY service_status), undef, $user_id, $user_id);

    my $ret = {};
    $ret->{$_->[1]} = int($_->[0]) foreach @$res;

    return $ret;
}

sub state_code_name
{
    my($self, $code) = @_;
    $self->fill_state_code_cache if !$self->{state_code_cache};
    my $name = $self->{state_code_cache}->{$code};
    return $name;
}

sub state_code_id
{
    my($self, $name) = @_;
    $self->fill_state_code_cache if !$self->{state_code_cache};
    my $code = $self->{state_name_cache}->{$name};
    return $code;
}

sub fill_state_code_cache
{
    my($self) = @_;
    my $c = $self->{state_code_cache} = {};
    my $n = $self->{state_name_cache} = {};
    my $res = $self->dbh->selectall_arrayref(qq(SELECT code, service_status FROM TaskState));
    $c->{$_->[0]} = $_->[1] foreach @$res;
    $n->{$_->[1]} = $_->[0] foreach @$res;
}

=item B<query_task_summary_async>

Return a summary of the counts of the task types for the specified user, asynchronous version.

=cut

sub query_task_summary_async
{
    my($self, $user_id, $cb) = @_;
    
    my $async = $self->async;
    $async->selectall_arrayref(qq(SELECT count(id) as count, state_code
				      FROM Task 
				      WHERE owner = ?
				      GROUP BY state_code), undef, $user_id, sub {
					  my($res) = @_;
					  my $ret = {};
					  $async;
					  $ret->{$self->state_code_name($_->[1])} = int($_->[0]) foreach @$res;
					  &$cb([$ret])});
}

=item B<query_task_summary_filtered>

Return a summary of the counts of task statuses for the specified user,
filtered by the given SimpleTaskFilter.

If include_archived is true, includes both Task and ArchivedTask tables.
The 'status' field in the filter is ignored since we want counts for ALL statuses.

=cut

sub query_task_summary_filtered
{
    my($self, $user_id, $simple_filter) = @_;

    # Build filter conditions, but exclude status since we want counts per status
    my ($cond, @param) = $self->_build_filter_conditions($user_id, $simple_filter, { exclude_status => 1 });

    my $include_archived = $simple_filter->{include_archived} ? 1 : 0;

    my $qry;
    my @all_params;

    if ($include_archived)
    {
	#
	# Query both Task and ArchivedTask tables with UNION ALL
	#
	$qry = qq(
	    SELECT service_status, SUM(cnt) as count FROM (
		SELECT ts.service_status, COUNT(t.id) as cnt
		FROM Task t JOIN TaskState ts ON t.state_code = ts.code
		WHERE $cond
		GROUP BY ts.service_status
		UNION ALL
		SELECT ts.service_status, COUNT(t.id) as cnt
		FROM ArchivedTask t JOIN TaskState ts ON t.state_code = ts.code
		WHERE $cond
		GROUP BY ts.service_status
	    ) combined
	    GROUP BY service_status
	);
	@all_params = (@param, @param);
    }
    else
    {
	#
	# Query only Task table (backward compatible behavior)
	#
	$qry = qq(
	    SELECT ts.service_status, COUNT(t.id) as count
	    FROM Task t JOIN TaskState ts ON t.state_code = ts.code
	    WHERE $cond
	    GROUP BY ts.service_status
	);
	@all_params = @param;
    }

    my $res = $self->dbh->selectall_arrayref($qry, undef, @all_params);

    my $ret = {};
    $ret->{$_->[0]} = int($_->[1]) foreach @$res;
    return $ret;
}

=item B<query_app_summary>

Return a summary of the counts of the apps for the specified user, asynchronous version.

=cut

sub query_app_summary
{
    my($self, $user_id) = @_;
    
    my $res = $self->dbh->selectall_arrayref(qq(SELECT count(id) as count, application_id
						FROM Task 
						WHERE owner = ?
						GROUP BY application_id), undef, $user_id);
    
    my $ret = {};
    $ret->{$_->[1]} = int($_->[0]) foreach @$res;
    return $ret;
}

=item B<query_app_summary_async>

Return a summary of the counts of the apps for the specified user, asynchronous version.

=cut

sub query_app_summary_async
{
    my($self, $user_id, $cb) = @_;
    
    my $async = $self->async;
    $async->selectall_arrayref(qq(SELECT count(id) as count, application_id
				      FROM Task
				      WHERE owner = ?
				      GROUP BY application_id), undef, $user_id, sub {
					  my($res) = @_;
					  $async;
					  my $ret = {};
					  $ret->{$_->[1]} = int($_->[0]) foreach @$res;
					  &$cb([$ret])});
}

=item B<_build_filter_conditions>

Build WHERE clause conditions and parameters from a SimpleTaskFilter.

Options:
  exclude_app => 1      Skip the app filter (used by query_app_summary_filtered)
  exclude_status => 1   Skip the status filter (used by query_task_summary_filtered)

Returns ($where_clause, @params)

=cut

sub _build_filter_conditions
{
    my($self, $user_id, $simple_filter, $opts) = @_;

    $opts //= {};

    require DateTime::Format::MySQL;
    require DateTime::Format::DateParse;

    my @cond;
    my @param;

    push(@cond, "owner = ?");
    push(@param, $user_id);

    if (my $t = $simple_filter->{start_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time >= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $t = $simple_filter->{end_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time <= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (!$opts->{exclude_app})
    {
	if (my $app = $simple_filter->{app})
	{
	    if ($app =~ /^[0-9a-zA-Z_]+$/)
	    {
		push(@cond, "t.application_id = ?");
		push(@param, $app);
	    }
	}
    }

    if (!$opts->{exclude_status})
    {
	if (my $st = $simple_filter->{status})
	{
	    if ($st =~ /^[-0-9a-zA-Z]+$/)
	    {
		push(@cond, "ts.service_status = ?");
		push(@param, $st);
	    }
	}
    }

    if (my $search_text = $simple_filter->{search})
    {
	push(@cond, "MATCH t.search_terms AGAINST (?)");
	push(@param, $search_text);
    }

    my $cond = join(" AND ", map { "($_)" } @cond);

    return ($cond, @param);
}

=item B<query_app_summary_filtered>

Return a summary of the counts of apps for the specified user,
filtered by the given SimpleTaskFilter.

If include_archived is true, includes both Task and ArchivedTask tables.
The 'app' field in the filter is ignored since we want counts for ALL apps.

=cut

sub query_app_summary_filtered
{
    my($self, $user_id, $simple_filter) = @_;

    my ($cond, @param) = $self->_build_filter_conditions($user_id, $simple_filter, { exclude_app => 1 });

    my $include_archived = $simple_filter->{include_archived} ? 1 : 0;

    my $qry;
    my @all_params;

    if ($include_archived)
    {
	#
	# Query both Task and ArchivedTask tables with UNION ALL
	#
	$qry = qq(
	    SELECT application_id, SUM(cnt) as count FROM (
		SELECT t.application_id, COUNT(t.id) as cnt
		FROM Task t JOIN TaskState ts ON t.state_code = ts.code
		WHERE $cond
		GROUP BY t.application_id
		UNION ALL
		SELECT t.application_id, COUNT(t.id) as cnt
		FROM ArchivedTask t JOIN TaskState ts ON t.state_code = ts.code
		WHERE $cond
		GROUP BY t.application_id
	    ) combined
	    GROUP BY application_id
	);
	@all_params = (@param, @param);
    }
    else
    {
	#
	# Query only Task table (backward compatible behavior)
	#
	$qry = qq(
	    SELECT t.application_id, COUNT(t.id) as count
	    FROM Task t JOIN TaskState ts ON t.state_code = ts.code
	    WHERE $cond
	    GROUP BY t.application_id
	);
	@all_params = @param;
    }

    my $res = $self->dbh->selectall_arrayref($qry, undef, @all_params);

    my $ret = {};
    $ret->{$_->[0]} = int($_->[1]) foreach @$res;
    return $ret;
}

=item B<enumerate_tasks>

Enumerate the given users tasks.

=cut

sub enumerate_tasks
{
    my($self, $user_id, $offset, $count) = @_;

    my $rec_start = $offset;
    my $rec_end = $offset + $count - 1;

    #
    # Count the active tasks and see if we need to dip into the archive.
    #
    
    my $res = $self->dbh->selectcol_arrayref(qq(SELECT COUNT(id)
						FROM Task
						WHERE owner = ?), undef, $user_id);
    my $need_active;
    my $need_archive;

    my $archive_offset;
    my $archive_count;
    
    my $active_count = $res->[0];

    if ($offset > $active_count)
    {
	$need_archive = 1;
	$archive_offset = $offset - $active_count;
	$archive_count = $count;
    }
    elsif ($rec_end > $active_count)
    {
	$need_archive = 1;
	$need_active = 1;
	$archive_offset = 0;

	$archive_count = $rec_end - $active_count;
    }
    else
    {
	$need_active = 1;
    }

    my $active_sth = $self->dbh->prepare(qq(SELECT id, parent_task, application_id, params, owner,
				     service_status,
				     IF(submit_time=default(submit_time), '', DATE_FORMAT(submit_time, '%Y-%m-%dT%TZ')) as submit_time,
				     IF(start_time=default(start_time), '', DATE_FORMAT(start_time,  '%Y-%m-%dT%TZ')) as start_time,
				     IF(finish_time=default(finish_time), '', DATE_FORMAT(finish_time, '%Y-%m-%dT%TZ')) as finish_time,
				     IF(finish_time != DEFAULT(finish_time) AND start_time != DEFAULT(start_time), timediff(finish_time, start_time), '') as elapsed_time

				     FROM Task JOIN TaskState on state_code = code
				     WHERE owner = ?
				     ORDER BY Task.submit_time DESC
				     LIMIT ?
				     OFFSET ?));

    my $archive_sth = $self->dbh->prepare(qq(SELECT id, parent_task, application_id, params, owner,
				     service_status,
				     IF(submit_time=default(submit_time), '', DATE_FORMAT(submit_time, '%Y-%m-%dT%TZ')) as submit_time,
				     IF(start_time=default(start_time), '', DATE_FORMAT(start_time,  '%Y-%m-%dT%TZ')) as start_time,
				     IF(finish_time=default(finish_time), '', DATE_FORMAT(finish_time, '%Y-%m-%dT%TZ')) as finish_time,
				     IF(finish_time != DEFAULT(finish_time) AND start_time != DEFAULT(start_time), timediff(finish_time, start_time), '') as elapsed_time

				     FROM ArchivedTask JOIN TaskState on state_code = code
				     WHERE owner = ?
				     ORDER BY submit_time DESC
				     LIMIT ?
				     OFFSET ?));


    my @need;
    push (@need, [$active_sth, $offset, $count]) if $need_active;
    push (@need, [$archive_sth, $archive_offset, $archive_count]) if $need_archive;

    my $ret = [];

    for my $ent (@need)
    {
	my($sth, $soffset, $scount) = @$ent;
	$sth->execute($user_id, $scount, $soffset);
	
	while (my $task = $sth->fetchrow_hashref())
	{
	    push(@$ret, $self->format_task_for_service($task));
	}
    }
    return $ret;
}

=item B<enumerate_tasks_async>

Enumerate the given user's tasks, asynchronous version.

=cut

sub enumerate_tasks_async
{
    my($self, $user_id, $offset, $count, $cb) = @_;

    my $async = $self->async;
    my $prep_cb = sub {
	my($rv, $sth) = @_;
	$async;
	my $ret = [];
	while (my$ task = $sth->fetchrow_hashref())
	{
	    push(@$ret, $self->format_task_for_service($task));
	}
	&$cb([$ret]);
    };

    my $qry = qq(SELECT id, parent_task, application_id, params, owner,
				     service_status,
				     DATE_FORMAT(CONVERT_TZ(submit_time, \@\@session.time_zone, '+00:00'), '%Y-%m-%dT%TZ') as submit_time,
				     DATE_FORMAT(CONVERT_TZ(start_time, \@\@session.time_zone, '+00:00'), '%Y-%m-%dT%TZ') as start_time,
				     DATE_FORMAT(CONVERT_TZ(finish_time, \@\@session.time_zone, '+00:00'), '%Y-%m-%dT%TZ') as finish_time
				     FROM Task JOIN TaskState on state_code = code
				     WHERE owner = ?
				     ORDER BY submit_time DESC
				     LIMIT ?
				     OFFSET ?);
    my $sth = $async->prepare($qry);
    $sth->execute($user_id, $count, $offset, $prep_cb);
}

=item B<enumerate_tasks_filtered_async>

Enumerate the given user's tasks, asynchronous version.

The $simple_filter is a hash with keys start_time, end_time, app, search.

=cut

sub enumerate_tasks_filtered_async
{
    my($self, $user_id, $offset, $count, $simple_filter, $cb) = @_;

    my @cond;
    my @param;

    push(@cond, "owner = ?");
    push(@param, $user_id);

    if (my $t = $simple_filter->{start_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time >= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $t = $simple_filter->{end_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time <= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $app = $simple_filter->{app})
    {
	if ($app =~ /^[0-aA-Za-z]+$/)
	{
	    push(@cond, "t.application_id = ?");
	    push(@param, $app);
	}
    }

    if (my $st = $simple_filter->{status})
    {
	if ($st =~ /^[-0-aA-Za-z]+$/)
	{
	    push(@cond, "ts.service_status = ?");
	    push(@param, $st);
	}

    }
    if (my $search_text = $simple_filter->{search})
    {
	push(@cond, "MATCH t.search_terms AGAINST (?)");
	push(@param, $search_text);
    }
    
    my $cond = join(" AND ", map { "($_)" } @cond);

    my $ret_fields = "t.id, t.parent_task, t.application_id, t.params, t.owner, ";
    for my $x (qw(submit_time start_time finish_time))
    {
	$ret_fields .= "DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ') as $x, ";
    }
    $ret_fields .= "timediff(t.finish_time, t.start_time) as elapsed_time, ts.service_status";

    my $qry = qq(SELECT $ret_fields
		 FROM Task t JOIN TaskState ts on t.state_code = ts.code
		 WHERE $cond
		 ORDER BY t.submit_time DESC
		 LIMIT ?
		 OFFSET ?);
    my $count_qry = qq(SELECT COUNT(t.id)
		       FROM Task t JOIN TaskState ts on t.state_code = ts.code
		       WHERE $cond);

    my $all_ret = [];
    my $cv = AnyEvent->condvar;

    my $async = $self->async;

    $cv->begin;
    
    my $enumerate_cb = sub {
	my($rv, $sth) = @_;
	print STDERR "outer query returns $rv\n";
	$async;			#  Hold lexical ref
	my $ret = [];
	while (my $task = $sth->fetchrow_hashref())
	{
	    push(@$ret, $self->format_task_for_service($task));
	}
	$all_ret->[0] = $ret;

	$cv->end();
    };

    my $sth = $async->prepare($qry);

    print STDERR "execute outer query $qry\n";
    $cv->begin();
    $sth->execute(@param, $count, $offset, $enumerate_cb);

    my $async2 = $self->async;

    my $count_cb = sub {
	my($rv, $sth) = @_;

	$async2;		# Hold lexical ref
	print STDERR "Inner query returns $rv\n";
	my $row = $sth->fetchrow_arrayref();
	print Dumper($row);
	$all_ret->[1] = int($row->[0]);
	$cv->end();
    };

    my $sth2 = $async2->prepare($count_qry);
    $cv->begin();
    $sth2->execute(@param, $count_cb);

    $cv->cb(sub { print "FINISH \n"; $cb->($all_ret); });
    $cv->end();
}

=item B<enumerate_tasks_filtered>

Enumerate the task owned by the given user.

The $simple_filter is a hash with keys start_time, end_time, app, search, status, include_archived,
sort_field, and sort_order.

If include_archived is true, queries both Task and ArchivedTask tables with
pagination that spans across tables (active tasks first, then archived).

Supported sort_field values: submit_time (default), start_time, finish_time,
application_id, service_status, id, output_name.

Supported sort_order values: desc (default), asc.

=cut

sub enumerate_tasks_filtered
{
    my($self, $user_id, $offset, $count, $simple_filter, $cb) = @_;

    my ($cond, @param) = $self->_build_filter_conditions($user_id, $simple_filter);

    my $include_archived = $simple_filter->{include_archived} ? 1 : 0;

    #
    # Build ORDER BY clause from sort_field and sort_order
    #
    my %valid_sort_fields = (
	submit_time    => 't.submit_time',
	start_time     => 't.start_time',
	finish_time    => 't.finish_time',
	application_id => 't.application_id',
	service_status => 'ts.service_status',
	id             => 't.id',
	output_file    => 't.output_file',
    );

    my $sort_field = $simple_filter->{sort_field} // 'submit_time';
    my $sort_order = lc($simple_filter->{sort_order} // 'desc');

    # Validate sort_field - fall back to submit_time if invalid
    my $order_col = $valid_sort_fields{$sort_field} // 't.submit_time';

    # Validate sort_order - fall back to DESC if invalid
    $sort_order = 'desc' unless $sort_order eq 'asc';

    my $order_clause = "ORDER BY $order_col " . uc($sort_order);

    my $ret_fields = "t.id, t.parent_task, t.application_id, t.params, t.owner, ";
    for my $x (qw(submit_time start_time finish_time))
    {
	$ret_fields .= "IF($x = default($x), '', DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ')) as $x, ";
    }
    $ret_fields .= "if(t.finish_time != default(t.finish_time) and t.start_time != default(t.start_time), timediff(t.finish_time, t.start_time), '') as elapsed_time, ";
    $ret_fields .= " ts.service_status";

    my $dbh = $self->dbh;

    if (!$include_archived)
    {
	#
	# Original behavior: query only Task table
	#
	my $qry = qq(SELECT $ret_fields
		     FROM Task t JOIN TaskState ts on t.state_code = ts.code
		     WHERE $cond
		     $order_clause
		     LIMIT ?
		     OFFSET ?);
	my $count_qry = qq(SELECT COUNT(t.id)
			   FROM Task t JOIN TaskState ts on t.state_code = ts.code
			   WHERE $cond);

	my $sth = $dbh->prepare($qry);
	$sth->execute(@param, $count, $offset);

	my $tasks = [];
	while (my $task = $sth->fetchrow_hashref())
	{
	    push(@$tasks, $self->format_task_for_service($task));
	}

	$sth = $dbh->prepare($count_qry);
	$sth->execute(@param);

	my $row = $sth->fetchrow_arrayref();
	my $total = int($row->[0]);

	return ($tasks, $total);
    }

    #
    # Include archived tasks: pagination spans Task -> ArchivedTask
    #

    # Count active (Task) tasks matching filter
    my $active_count_qry = qq(SELECT COUNT(t.id)
			      FROM Task t JOIN TaskState ts ON t.state_code = ts.code
			      WHERE $cond);
    my $active_count = $dbh->selectcol_arrayref($active_count_qry, undef, @param)->[0] // 0;

    # Count archived tasks matching filter
    my $archive_count_qry = qq(SELECT COUNT(t.id)
			       FROM ArchivedTask t JOIN TaskState ts ON t.state_code = ts.code
			       WHERE $cond);
    my $archive_total = $dbh->selectcol_arrayref($archive_count_qry, undef, @param)->[0] // 0;

    my $total_tasks = $active_count + $archive_total;

    #
    # Determine which tables to query based on offset/count
    #
    my $rec_start = $offset;
    my $rec_end = $offset + $count - 1;

    my $need_active = 0;
    my $need_archive = 0;
    my $active_offset = 0;
    my $active_limit = 0;
    my $archive_offset = 0;
    my $archive_limit = 0;

    if ($offset >= $active_count)
    {
	# Entirely in archive
	$need_archive = 1;
	$archive_offset = $offset - $active_count;
	$archive_limit = $count;
    }
    elsif ($rec_end >= $active_count)
    {
	# Spans both tables
	$need_active = 1;
	$need_archive = 1;
	$active_offset = $offset;
	$active_limit = $active_count - $offset;
	$archive_offset = 0;
	$archive_limit = $count - $active_limit;
    }
    else
    {
	# Entirely in active
	$need_active = 1;
	$active_offset = $offset;
	$active_limit = $count;
    }

    my $tasks = [];

    if ($need_active)
    {
	my $active_qry = qq(SELECT $ret_fields
			    FROM Task t JOIN TaskState ts ON t.state_code = ts.code
			    WHERE $cond
			    $order_clause
			    LIMIT ?
			    OFFSET ?);
	my $sth = $dbh->prepare($active_qry);
	$sth->execute(@param, $active_limit, $active_offset);
	while (my $task = $sth->fetchrow_hashref())
	{
	    push(@$tasks, $self->format_task_for_service($task));
	}
    }

    if ($need_archive)
    {
	my $archive_qry = qq(SELECT $ret_fields
			     FROM ArchivedTask t JOIN TaskState ts ON t.state_code = ts.code
			     WHERE $cond
			     $order_clause
			     LIMIT ?
			     OFFSET ?);
	my $sth = $dbh->prepare($archive_qry);
	$sth->execute(@param, $archive_limit, $archive_offset);
	while (my $task = $sth->fetchrow_hashref())
	{
	    push(@$tasks, $self->format_task_for_service($task));
	}
    }

    return ($tasks, $total_tasks);
}

sub format_task_for_service
{
    my($self, $task) = @_;

    my $params = eval { decode_json($task->{params}) };
    if ($@)
    {
	# warn "Error parsing params for task $task->{id}: '$task->{params}'\n";
	$params = {};
    }
    #die Dumper($task);

    #
    # Custom rewrites here.
    #
    my $visible_application_name = $task->{application_id};
    
    if ($task->{application_id} eq 'GeneTree')
    {
	if ($params->{tree_type} eq 'viral_genome')
	{
	    $visible_application_name = "Viral Genome Tree";
	}
	elsif ($params->{tree_type} eq 'gene')
	{
	    $visible_application_name = "Gene Tree";
	}
    }

    my $rtask = {
	id => $task->{id},
	parent_id  => $task->{parent_task},
	app => $task->{application_id},
	workspace => undef,
	parameters => $params,
	user_id => $task->{owner},
	status => $task->{service_status},
	submit_time => $task->{submit_time},
	start_time => $task->{start_time},
	completed_time => $task->{finish_time},
	elapsed_time => "" . $task->{elapsed_time},
        storage_location => "" . $task->{storage_location},
	application_name => $visible_application_name,
    };
    return $rtask;
}

#
# Retrieve job details for Jira submission
#

sub retrieve_task_details_jira
{
    my($self, $task_id, $owner) = @_;

    my $res = $self->dbh->selectrow_hashref(qq(SELECT t.id as task_id, t.application_id as app_name,
					       t.params as parameters,
					       st.service_status as task_status,
					       date_format(t.submit_time, "%Y-%m-%dT%H:%i:%s") as submit_time,
					       date_format(t.start_time, "%Y-%m-%dT%H:%i:%s") as start_time,
					       date_format(t.finish_time, "%Y-%m-%dT%H:%i:%s") as completion_time,
					       cj.exitcode as exit_status, cj.job_status as cluster_status
					       FROM Task t LEFT OUTER JOIN TaskExecution te ON te.task_id = t.id 
					       LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
					       JOIN TaskState st ON t.state_code = st.code
					       WHERE t.id = ? AND t.owner = ?), undef, $task_id, $owner);
    $res->{task_id} = int($res->{task_id}) if $res;
    return $res // {};
}

#
# Maintenance routines
#


#
# Reset a job back to queued status.
#

sub reset_job
{
    my($self, $job, $reset_params) = @_;

    my $res = $self->dbh->selectall_arrayref(qq(SELECT  t.state_code, t.owner, te.active
						FROM Task t LEFT OUTER JOIN  TaskExecution te ON t.id = te.task_id
						WHERE id = ?), undef, $job);

    my $has_task_execution;
    if (@$res)
    {
	my $skip;
	print STDERR "Job records for $job:\n";
	for my $ent (@$res)
	{
	    
	    my($state, $owner, $active) = @$ent;

	    $has_task_execution++ if defined($active);
	    
	    $active //= "<NULL>";
	    print STDERR "\t$state\t$owner\t$active\n";
	    if ($state eq 'Q')
	    {
		$skip++;
	    }
	}
	if ($skip)
	{
	    print STDERR "Job $job is already in state Q, not changing\n";
	    return;
	}
	my @params;
	my $reset;
	if ($reset_params)
	{
	    if ($reset_params->{time})
	    {
		push(@params, $reset_params->{time});
		$reset .= ", t.req_runtime = ?";
	    }
	    if ($reset_params->{memory})
	    {
		push(@params, $reset_params->{memory});
		$reset .= ", t.req_memory = ?";
	    }
	    if ($reset_params->{cpu})
	    {
		push(@params, $reset_params->{cpu});
		$reset .= ", t.req_cpu = ?";
	    }
	    if ($reset_params->{data_container_id})
	    {
		push(@params, $reset_params->{data_container_id});
		$reset .= ", t.data_container_id = ?";
	    }
	    if ($reset_params->{container_id})
	    {
		push(@params, $reset_params->{container_id});
		$reset .= ", t.container_id = ?";
	    }
	}

	my $res;
	if ($has_task_execution)
	{
	    $res = $self->dbh->do(qq(UPDATE Task t,  TaskExecution te
				     SET t.state_code='Q', te.active = 0 $reset
				     WHERE t.id = te.task_id AND
				     id = ?), undef,  @params, $job);
	}
	else
	{
	    my $qry = qq(UPDATE Task t
				     SET t.state_code='Q' $reset
				     WHERE 
				     id = ?);
	    
	    $res = $self->dbh->do($qry, undef,  @params, $job);
	}
	print STDERR "Update returns $res\n";
    }
							    
}

1;
