SET default_storage_engine=INNODB;
drop table if exists TaskExecution;
drop table if exists ClusterJob;
drop table if exists Cluster;
drop table if exists ClusterType;
drop table if exists TaskToken;
drop table if exists Task;
drop table if exists ServiceUser;
drop table if exists Project;
drop table if exists TaskState;
drop table if exists Application;

DROP TABLE IF EXISTS ClusterType;
CREATE TABLE ClusterType
(
	type VARCHAR(255) PRIMARY KEY
);
INSERT INTO ClusterType VALUES ('AWE'), ('Slurm');

DROP TABLE IF EXISTS Container;
CREATE TABLE Container
(
	id VARCHAR(255) PRIMARY KEY,
	filename VARCHAR(255),	
	creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

DROP TABLE IF EXISTS DataContainer;
CREATE TABLE DataContainer
(
	id VARCHAR(255) PRIMARY KEY,
	name VARCHAR(255)
);

DROP TABLE IF EXISTS SiteDefaultContainer;
CREATE TABLE SiteDefaultContainer
(
	base_url VARCHAR(255) PRIMARY KEY,
	default_container_id VARCHAR(255),
	FOREIGN KEY (default_container_id) REFERENCES Container(id)
);

DROP TABLE IF EXISTS SiteDefaultDataContainer;
CREATE TABLE SiteDefaultDataContainer
(
	base_url VARCHAR(255) PRIMARY KEY,
	default_data_container_id VARCHAR(255),
	FOREIGN KEY (default_data_container_id) REFERENCES DataContainer(id)
);

CREATE TABLE Cluster
(
	id varchar(255) PRIMARY KEY,
	type varchar(255),
	name varchar(255),
	account varchar(255),
	remote_host varchar(255),
	remote_user varchar(255),
	remote_keyfile varchar(255),
	scheduler_install_path text,
	temp_path text,
	p3_runtime_path text,
	p3_deployment_path text,
	max_allowed_jobs int,
	submit_queue varchar(255),
	submit_cluster varchar(255),
	container_repo_url varchar(255),
	container_cache_dir varchar(255),
	default_container_id varchar(255),
	default_data_container_id varchar(255),
	default_data_directory varchar(255),
	data_container_search_path varchar(1024),
	FOREIGN KEY (type) REFERENCES ClusterType(type),
	FOREIGN KEY (default_container_id) REFERENCES Container(id),
	FOREIGN KEY (default_data_container_id) REFERENCES DataContainer(id)
) ;
INSERT INTO Cluster (id, type, name, scheduler_install_path, temp_path, p3_runtime_path, p3_deployment_path, 
       remote_host, account, remote_user, remote_keyfile) VALUES 
       ('P3AWE', 'AWE', 'PATRIC AWE Cluster', NULL, '/disks/tmp', '/disks/patric-common/runtime', '/disks/p3/deployment', NULL, NULL, NULL, NULL),
       ('TSlurm', 'Slurm', 'Test SLURM Cluster', '/disks/patric-common/slurm', '/disks/tmp', 
       		  '/disks/patric-common/runtime', '/home/olson/P3/dev-slurm/dev_container', NULL, NULL, NULL, NULL),
       ('P3Slurm', 'Slurm', 'P3 SLURM Cluster', '/disks/patric-common/slurm', '/disks/tmp', 
       		  '/disks/patric-common/runtime', '/vol/patric3/production/P3Slurm/deployment', NULL, NULL, NULL, NULL),
       ('Bebop', 'Slurm', 'Bebop', '/usr/bin', '/scratch', '/home/olson/P3/bebop/runtime', '/home/olson/P3/bebop/dev_container',
       		 'bebop.lcrc.anl.gov', 'PATRIC', 'olson', '/homes/olson/P3/dev-slurm/dev_container/bebop.key');


CREATE TABLE TaskState
(
	code VARCHAR(10) PRIMARY KEY,
	description VARCHAR(255),
	service_status VARCHAR(20)
);

INSERT INTO TaskState VALUES
       ('Q', 'Queued', 'queued'),
       ('S', 'Submitted to cluster', 'pending'),
       ('C', 'Completed', 'completed'),
       ('F', 'Failed', 'failed'),
       ('D', 'Deleted', 'deleted'),
       ('T', 'Terminated', 'failed');

CREATE TABLE Application
(
	id VARCHAR(255) PRIMARY KEY,
	script VARCHAR(255),
	spec TEXT,
	default_memory VARCHAR(255),
	default_cpu INTEGER,
	display_order INTEGER
);

DROP TABLE IF EXISTS ApplicationDefaultContainer;
CREATE TABLE ApplicationDefaultContainer
(
	application_id VARCHAR(255) PRIMARY KEY,
	default_container_id VARCHAR(2155),
	FOREIGN KEY (default_container_id) REFERENCES Container(id)
);

DROP TABLE IF EXISTS  ApplicationSpec;
CREATE TABLE ApplicationSpec
(
	id VARCHAR(64) PRIMARY KEY, -- this is the sha-256 hash of the spec document in hex format
	application_id VARCHAR(255),
	spec JSON,
	first_seen timestamp,
	FOREIGN KEY (application_id) REFERENCES Application(id)
);

CREATE TABLE Project
(
	id VARCHAR(255) PRIMARY KEY,
	userid_domain VARCHAR(255)
);
INSERT INTO Project VALUES 
       ('PATRIC', 'patricbrc.org'), 
       ('RAST', 'rast.nmpdr.org'),
       ('ViPR', 'viprbrc.org'),
       ('BV-BRC', 'bvbrc');

CREATE TABLE ServiceUser
(     
	id VARCHAR(255) PRIMARY KEY,
	project_id VARCHAR(255),
	first_name VARCHAR(255),
	last_name VARCHAR(255),
	email VARCHAR(255),
	affiliation VARCHAR(255),
	is_staff BOOLEAN,
	is_collaborator BOOLEAN,
	FOREIGN KEY (project_id) REFERENCES Project(id)
);

CREATE TABLE Task
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	owner VARCHAR(255),
	parent_task INTEGER,
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	submit_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	start_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	finish_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	monitor_url VARCHAR(255),
	output_path TEXT,
	output_file TEXT,
	params TEXT,
	app_spec TEXT,
	req_memory VARCHAR(255),
	req_cpu INTEGER,
	req_runtime INTEGER,
	req_policy_data TEXT,
	req_is_control_task BOOLEAN,
	search_terms text,
	hidden BOOLEAN default FALSE,
	container_id VARCHAR(255),
	data_container_id VARCHAR(255),
	base_url VARCHAR(255),
	user_metadata TEXT,
	FOREIGN KEY (owner) REFERENCES ServiceUser(id),
	FOREIGN KEY (state_code) REFERENCES TaskState(code),
	FOREIGN KEY (application_id) REFERENCES Application(id),
	FOREIGN KEY (parent_task) REFERENCES Task(id),
	FOREIGN KEY (container_id) REFERENCES Container(id),
	FOREIGN KEY (data_container_id) REFERENCES DataContainer(id),
	FULLTEXT KEY search_idx(search_terms)
);

DROP TABLE IF EXISTS ArchivedTask;
CREATE TABLE ArchivedTask
(
	id INTEGER,
	retry_index INTEGER,
	owner VARCHAR(255),
	parent_task INTEGER,
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	submit_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	start_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	finish_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	monitor_url VARCHAR(255),
	output_path  TEXT,
	output_file TEXT,
	params JSON,
	app_spec_id VARCHAR(64),
	req_memory VARCHAR(255),
	req_cpu INTEGER,
	req_runtime INTEGER,
	req_policy_data TEXT,
	req_is_control_task BOOLEAN,
	search_terms text,
	hidden BOOLEAN default FALSE,
	container_id VARCHAR(255),
	data_container_id VARCHAR(255),
	base_url VARCHAR(255),
	user_metadata TEXT,

	-- Following are the denormalized fields from TaskExecution
	cluster_job_id INTEGER,
	active BOOLEAN,
	
	-- Following are the denormalized fields from ClusterJob

	cluster_id VARCHAR(255),
	job_id VARCHAR(255),
	job_status VARCHAR(255),
	maxrss float,
	nodelist TEXT,
	exitcode VARCHAR(255),

	INDEX (job_id),
	INDEX (owner_id, application_id),
	PRIMARY KEY (id, submit_time, retry_index)
)
PARTITION BY RANGE ( UNIX_TIMESTAMP(submit_time) ) (
PARTITION p_2014_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2014-01-01 00:00:00') ),
PARTITION p_2015_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2015-01-01 00:00:00') ),
PARTITION p_2016_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2016-01-01 00:00:00') ),
PARTITION p_2017_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2017-01-01 00:00:00') ),
PARTITION p_2018_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2018-01-01 00:00:00') ),
PARTITION p_2019_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2019-01-01 00:00:00') ),
PARTITION p_2019_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2019-04-01 00:00:00') ),
PARTITION p_2019_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2019-07-01 00:00:00') ),
PARTITION p_2019_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2019-10-01 00:00:00') ),
PARTITION p_2020_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2020-01-01 00:00:00') ),
PARTITION p_2020_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2020-04-01 00:00:00') ),
PARTITION p_2020_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2020-07-01 00:00:00') ),
PARTITION p_2020_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2020-10-01 00:00:00') ),
PARTITION p_2021_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2021-01-01 00:00:00') ),
PARTITION p_2021_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2021-04-01 00:00:00') ),
PARTITION p_2021_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2021-07-01 00:00:00') ),
PARTITION p_2021_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2021-10-01 00:00:00') ),
PARTITION p_2022_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2022-01-01 00:00:00') ),
PARTITION p_2022_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2022-04-01 00:00:00') ),
PARTITION p_2022_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2022-07-01 00:00:00') ),
PARTITION p_2022_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2022-10-01 00:00:00') ),
PARTITION p_2023_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2023-01-01 00:00:00') ),
PARTITION p_2023_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2023-04-01 00:00:00') ),
PARTITION p_2023_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2023-07-01 00:00:00') ),
PARTITION p_2023_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2023-10-01 00:00:00') ),
PARTITION p_2024_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2024-01-01 00:00:00') ),
PARTITION p_2024_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2024-04-01 00:00:00') ),
PARTITION p_2024_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2024-07-01 00:00:00') ),
PARTITION p_2024_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2024-10-01 00:00:00') ),
PARTITION p_2025_01 VALUES LESS THAN ( UNIX_TIMESTAMP('2025-01-01 00:00:00') ),
PARTITION p_2025_04 VALUES LESS THAN ( UNIX_TIMESTAMP('2025-04-01 00:00:00') ),
PARTITION p_2025_07 VALUES LESS THAN ( UNIX_TIMESTAMP('2025-07-01 00:00:00') ),
PARTITION p_2025_10 VALUES LESS THAN ( UNIX_TIMESTAMP('2025-10-01 00:00:00') ),
     PARTITION p_last VALUES LESS THAN (MAXVALUE)
);

DROP TABLE IF EXISTS TaskParams;
CREATE TABLE TaskParams
(
	task_id INTEGER PRIMARY KEY,
	FOREIGN KEY (task_id) REFERENCES Task(id),
	app_spec JSON,
	params JSON,
	preflight JSON
);

DROP TABLE IF EXISTS loader;
CREATE TABLE loader
(
cluster_job_id varchar(36),
	owner VARCHAR(255),
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	submit_time TIMESTAMP,
	start_time TIMESTAMP ,
	finish_time TIMESTAMP,

	output_path TEXT,
	output_file TEXT,
exit_code varchar(6),
hostname varchar(255),
params text
	);

CREATE TABLE ClusterJob
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	cluster_id VARCHAR(255),
	job_id VARCHAR(255),
	job_status VARCHAR(255),
	maxrss float,
	nodelist TEXT,
	exitcode VARCHAR(255),
	cancel_requested BOOLEAN,
	INDEX (job_id),
	FOREIGN KEY(cluster_id) REFERENCES Cluster(id)
) ;

CREATE TABLE TaskExecution
(
	task_id INTEGER NOT NULL,
	cluster_job_id INTEGER NOT NULL,
	active BOOLEAN NOT NULL,
	index(task_id),
	index(cluster_job_id),
	FOREIGN KEY (task_id) REFERENCES Task(id),
	FOREIGN KEY (cluster_job_id) REFERENCES ClusterJob(id)
);

CREATE TABLE TaskToken
(
	task_id INTEGER,
	token TEXT,
	expiration TIMESTAMP DEFAULT NULL,
	FOREIGN KEY (task_id) REFERENCES Task(id)
);

DROP VIEW TaskWithActiveJob;
CREATE VIEW TaskWithActiveJob AS
SELECT t.*, cj.id as cluster_job_id, cj.cluster_id, cj.job_id as cluster_job, cj.job_status, cj.exitcode,
       cj.nodelist, cj.maxrss, cj.cancel_requested
FROM Task t 
     JOIN TaskExecution te ON t.id = te.task_id
     JOIN ClusterJob cj ON cj.id = te.cluster_job_id
WHERE te.active = 1;

--
-- View that is a union query of the live task data along with the 
-- archived tasks. 
-- 
DROP VIEW IF EXISTS AllTasks;
CREATE VIEW AllTasks AS
SELECT id, submit_time, application_id, owner, state_code, base_url
FROM ArchivedTask
WHERE active = 1
UNION
SELECT id, submit_time, application_id, owner, state_code, base_url
FROM Task
WHERE id > (SELECT IF(ISNULL(MAX(id)), 0, MAX(id)) FROM ArchivedTask)
;

DROP VIEW IF EXISTS MergedTaskStatus;
CREATE VIEW MergedTaskStatus AS
SELECT t.id, t.owner, t.state_code, cj.job_status
FROM Task t
     LEFT OUTER JOIN TaskExecution te ON t.id = te.task_id
     LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
WHERE te.active = 1 OR te.active IS NULL;

DROP VIEW IF EXISTS StatsGatherNonCollab;
CREATE VIEW StatsGatherNonCollab AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) AS year, t.application_id, COUNT(t.id) AS job_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id NOT IN ('Date', 'Sleep') AND
      u.is_collaborator = 0 AND
      u.is_staff = 0 AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;

DROP VIEW IF EXISTS StatsGatherCollab;
CREATE VIEW StatsGatherCollab AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) as year, 
       CONCAT(t.application_id, '-collab') AS application_id, COUNT(t.id) as job_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id IN ('GenomeAssembly', 'GenomeAssembly2', 'GenomeAnnotation') AND
      u.is_collaborator = 1 AND
      u.is_staff = 0 AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;

DROP VIEW IF EXISTS StatsGather;
CREATE VIEW StatsGather
AS SELECT * FROM StatsGatherCollab UNION SELECT * FROM StatsGatherNonCollab
   ORDER BY year, month, application_id;



DROP VIEW IF EXISTS BySiteStatsGatherNonCollab;
CREATE VIEW BySiteStatsGatherNonCollab AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) AS year, t.application_id, if(locate("bv-brc", t.base_url) > 0, 'BV-BRC', 'PATRIC') as site, COUNT(t.id) AS job_count
FROM AllTasks t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id NOT IN ('Date', 'Sleep') AND
      u.is_collaborator = 0 AND
      u.is_staff = 0 AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id, if(locate("bv-brc", t.base_url) > 0, 'BV-BRC', 'PATRIC')
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id, if(locate("bv-brc", t.base_url) > 0, 'BV-BRC', 'PATRIC');

DROP VIEW IF EXISTS BySiteStatsGatherCollab;
CREATE VIEW BySiteStatsGatherCollab AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) as year, 
       CONCAT(t.application_id, '-collab') AS application_id, if(locate("bv-brc", t.base_url) > 0, 'BV-BRC', 'PATRIC') as site, COUNT(t.id) as job_count
FROM AllTasks t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id IN ('GenomeAssembly', 'GenomeAssembly2', 'GenomeAnnotation') AND
      u.is_collaborator = 1 AND
      u.is_staff = 0 AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id, if(locate("bv-brc", t.base_url) > 0, 'BV-BRC', 'PATRIC')
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id, if(locate("bv-brc", t.base_url) > 0, 'BV-BRC', 'PATRIC');

DROP VIEW IF EXISTS BySiteStatsGather;
CREATE VIEW BySiteStatsGather
AS SELECT * FROM BySiteStatsGatherCollab UNION SELECT * FROM BySiteStatsGatherNonCollab
   ORDER BY year, month, application_id, site;






DROP VIEW IF EXISTS StatsGatherAll;
CREATE VIEW StatsGatherAll AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) AS year, t.application_id, COUNT(t.id) AS job_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id NOT IN ('Date', 'Sleep') AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;

DROP VIEW IF EXISTS StatsGatherUser;
CREATE VIEW StatsGatherUser AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) AS year, t.application_id, COUNT(distinct t.owner) AS user_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id NOT IN ('Date', 'Sleep') AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;

