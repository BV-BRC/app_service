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
    
    my $dbh =  $self->{dbh} = DBI->connect($self->dsn, $self->user, $self->pass, { AutoCommit => 1, RaiseError => 1 });
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
    # Don't cache. This lets us have multiple handles flowing.
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
				     UNION
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

    my $res = $self->dbh->selectall_arrayref(qq(SELECT count(id) as count, state_code
						FROM (SELECT id, state_code
						      FROM Task 
						      WHERE owner = ?
						      UNION
						      SELECT id, state_code
						      FROM ArchivedTask 
						      WHERE owner = ?) as t
						GROUP BY state_code), undef, $user_id, $user_id);

    my $ret = {};
    $ret->{$self->state_code_name($_->[1])} = int($_->[0]) foreach @$res;

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

Enumerate the given user's tasks.

The $simple_filter is a hash with keys start_time, end_time, app, search.

=cut

sub enumerate_tasks_filtered
{
    my($self, $user_id, $offset, $count, $simple_filter, $cb) = @_;

    my @cond;
    my @param;

    require DateTime::Format::MySQL;
    require DateTime::Format::DateParse;

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
	$ret_fields .= "IF($x = default($x), '', DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ')) as $x, ";
	# $ret_fields .= "DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ') as $x, ";
    }
    $ret_fields .= "if(t.finish_time != default(t.finish_time) and t.start_time != default(t.start_time), timediff(t.finish_time, t.start_time), '') as elapsed_time, ";
    $ret_fields .= " ts.service_status";

    my $qry = qq(SELECT $ret_fields
		 FROM Task t JOIN TaskState ts on t.state_code = ts.code
		 WHERE $cond
		 ORDER BY t.submit_time DESC
		 LIMIT ?
		 OFFSET ?);
    my $count_qry = qq(SELECT COUNT(t.id)
		       FROM Task t JOIN TaskState ts on t.state_code = ts.code
		       WHERE $cond);

    my $dbh = $self->dbh;

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
    print Dumper($row);
    my $count = int($row->[0]);

    return ($tasks, $count);
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
