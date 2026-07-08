module AppService
{
    authentication required;
    
    typedef string task_id;
    typedef string app_id;
    typedef string workspace_id;

    typedef mapping<string, string> task_parameters;

    typedef structure {
	string id;
	string label;
	int required;
	string default;
	string desc;
	string type;
	string enum;
	string wstype;
    } AppParameter;

    typedef structure {
	app_id id;
	string script;
	string label;
	string description;
	list<AppParameter> parameters;
    } App;
    
    typedef string task_status;

    typedef structure {
	task_id id;
	task_id parent_id;
	app_id app;
	workspace_id workspace;
	task_parameters parameters;
	string user_id;

	task_status status;
	task_status awe_status;
	string submit_time;
	string start_time;
	string completed_time;
	string elapsed_time;

	string stdout_shock_node;
	string stderr_shock_node;

    } Task;

    typedef structure {
	task_id id;
	App app;
	task_parameters parameters;
	float start_time;
	float end_time;
	float elapsed_time;
	string hostname;
	list <tuple<string output_path, string output_id>> output_files;
    } TaskResult;

    funcdef service_status() returns (tuple<int submission_enabled, string status_message>);

    funcdef enumerate_apps()
	returns (list<App>);

    funcdef start_app(app_id, task_parameters params, workspace_id workspace)
	returns (Task task);

    typedef structure {
        task_id parent_id;
	workspace_id workspace;
	string base_url;
	string container_id;
	string user_metadata;
	string reservation;
	string data_container_id;
	int disable_preflight;
	mapping<string, string> preflight_data;
    } StartParams;
    funcdef start_app2(app_id, task_parameters params, StartParams start_params)
	returns (Task task);

    funcdef query_tasks(list<task_id> task_ids)
	returns (mapping<task_id, Task task> tasks);

    funcdef query_task_summary() returns (mapping<task_status status, int count> status);

    funcdef query_app_summary() returns (mapping<app_id app, int count> status);

    typedef structure {
	string stdout_url;
	string stderr_url;
	int pid;
	string hostname;
	int exitcode;
    } TaskDetails;
    funcdef query_task_details(task_id) returns (TaskDetails details);

    funcdef enumerate_tasks(int offset, int count)
	returns (list<Task>);

    typedef structure {
 	string start_time;
	string end_time;
	app_id app;
	string search;
	string status;
	int include_archived;
	string sort_field;
	string sort_order;
    } SimpleTaskFilter;
    funcdef enumerate_tasks_filtered(int offset, int count, SimpleTaskFilter simple_filter)
	returns (list<Task> tasks, int total_tasks);

    funcdef query_task_summary_filtered(SimpleTaskFilter simple_filter)
	returns (mapping<task_status status, int count> status);

    funcdef query_app_summary_filtered(SimpleTaskFilter simple_filter)
	returns (mapping<app_id app, int count> status);

    /*
     * Queue-inspection ("qstat") support.
     *
     * QStatFilter carries the filters supported by the p3x-qstat access
     * pattern plus cross-user controls. Visibility is enforced in the
     * implementation: a non-administrator may see only their own jobs unless
     * all_users is set, in which case the whole queue is returned but every
     * row the caller does not own is masked (id, owner and app blanked and
     * the "masked" flag set). Administrators (role-based token) see everything
     * unmasked and may restrict to a single owner.
     */
    typedef structure {
	string start_time;        /* submit_time >= */
	string end_time;          /* submit_time <  */
	string started_after;     /* start_time  >= */
	app_id app;
	string status;            /* state_code (comma-separated list allowed) */
	string cluster;
	list<string> compute_nodes;
	string user_metadata;
	int include_archived;
	int include_inactive;     /* include inactive cluster executions */
	int include_parameters;   /* return task parameters (own/admin rows only) */
	string sort_field;        /* submit_time|start_time|finish_time|application_id|status|id|maxrss */
	string sort_order;        /* asc|desc */
	string owner;             /* admin only: restrict to one owner */
	int all_users;            /* request whole queue (non-owned rows masked for non-admins) */
    } QStatFilter;

    typedef structure {
	task_id id;               /* "" when masked */
	string owner;             /* "" when masked */
	app_id app;               /* "" when masked */
	int masked;               /* 1 if this row is masked from the caller */
	task_status status;       /* TaskState description */
	string submit_time;
	string start_time;
	string finish_time;
	string elapsed_time;
	string output_path;
	string output_file;
	string user_metadata;
	int req_cpu;
	string req_memory;
	int req_runtime;
	string cluster_id;
	string cluster_job_id;    /* cluster (e.g. Slurm) job id */
	string cluster_job_status;
	string nodelist;
	float maxrss;
	task_parameters parameters;
    } QStatTask;

    funcdef enumerate_tasks_qstat(int offset, int count, QStatFilter filter)
	returns (list<QStatTask> tasks, int total_tasks);

    funcdef kill_task(task_id id) returns (int killed, string msg);
    funcdef kill_tasks(list<task_id> ids) returns (mapping<task_id, structure { int killed; string msg; }>);
    funcdef rerun_task(task_id id) returns (Task task);
};
