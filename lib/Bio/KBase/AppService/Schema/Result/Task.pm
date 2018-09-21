use utf8;
package Bio::KBase::AppService::Schema::Result::Task;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Task

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

=head1 TABLE: C<Task>

=cut

__PACKAGE__->table("Task");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 owner

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 255

=head2 parent_task

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 state_code

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 10

=head2 application_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 255

=head2 submit_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: '0000-00-00 00:00:00'
  is_nullable: 0

=head2 start_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: '0000-00-00 00:00:00'
  is_nullable: 0

=head2 finish_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: '0000-00-00 00:00:00'
  is_nullable: 0

=head2 monitor_url

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 params

  data_type: 'text'
  is_nullable: 1

=head2 app_spec

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "owner",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
  "parent_task",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "state_code",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 10 },
  "application_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
  "submit_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "0000-00-00 00:00:00",
    is_nullable => 0,
  },
  "start_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "0000-00-00 00:00:00",
    is_nullable => 0,
  },
  "finish_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "0000-00-00 00:00:00",
    is_nullable => 0,
  },
  "monitor_url",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "params",
  { data_type => "text", is_nullable => 1 },
  "app_spec",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 application

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Application>

=cut

__PACKAGE__->belongs_to(
  "application",
  "Bio::KBase::AppService::Schema::Result::Application",
  { id => "application_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);

=head2 owner

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::ServiceUser>

=cut

__PACKAGE__->belongs_to(
  "owner",
  "Bio::KBase::AppService::Schema::Result::ServiceUser",
  { id => "owner" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);

=head2 parent_task

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->belongs_to(
  "parent_task",
  "Bio::KBase::AppService::Schema::Result::Task",
  { id => "parent_task" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);

=head2 state_code

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::TaskState>

=cut

__PACKAGE__->belongs_to(
  "state_code",
  "Bio::KBase::AppService::Schema::Result::TaskState",
  { code => "state_code" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);

=head2 task_executions

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::TaskExecution>

=cut

__PACKAGE__->has_many(
  "task_executions",
  "Bio::KBase::AppService::Schema::Result::TaskExecution",
  { "foreign.task_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 task_tokens

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::TaskToken>

=cut

__PACKAGE__->has_many(
  "task_tokens",
  "Bio::KBase::AppService::Schema::Result::TaskToken",
  { "foreign.task_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 tasks

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->has_many(
  "tasks",
  "Bio::KBase::AppService::Schema::Result::Task",
  { "foreign.parent_task" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-09-21 11:23:56
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:tH3cRz5/QgFRxN6+A8SJFA

__PACKAGE__->many_to_many(cluster_jobs => 'task_executions', 'cluster_job');


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
