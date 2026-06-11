use utf8;
package Bio::KBase::AppService::Schema::Result::ApplicationDefaultContainer;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ApplicationDefaultContainer

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

=head1 TABLE: C<ApplicationDefaultContainer>

=cut

__PACKAGE__->table("ApplicationDefaultContainer");

=head1 ACCESSORS

=head2 application_id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 site_type

  data_type: 'varchar'
  is_nullable: 0
  default_value: ''
  size: 255

=head2 default_container_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 2155

=cut

__PACKAGE__->add_columns(
  "application_id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "site_type",
  { data_type => "varchar", is_nullable => 0, default_value => '', size => 255 },
  "default_container_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 2155 },
);

=head1 PRIMARY KEY

=over 4

=item * L</application_id>

=item * L</site_type>

=back

=cut

__PACKAGE__->set_primary_key("application_id", "site_type");

=head1 RELATIONS

=head2 default_container

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Container>

=cut

__PACKAGE__->belongs_to(
  "default_container",
  "Bio::KBase::AppService::Schema::Result::Container",
  { id => "default_container_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-18 10:56:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:1C6NyZJcnnRHywk/OjmurQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
