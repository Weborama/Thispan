use utf8;
package ThisPAN::Schema::Result::Module;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

ThisPAN::Schema::Result::Module

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

=head1 TABLE: C<module>

=cut

__PACKAGE__->table("module");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 name

  data_type: 'varchar'
  is_nullable: 0

=head2 distribution

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 rendered_pod_path

  data_type: 'varchar'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "name",
  { data_type => "varchar", is_nullable => 0 },
  "distribution",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "rendered_pod_path",
  { data_type => "varchar", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<name_unique>

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->add_unique_constraint("name_unique", ["name"]);

=head2 C<rendered_pod_path_unique>

=over 4

=item * L</rendered_pod_path>

=back

=cut

__PACKAGE__->add_unique_constraint("rendered_pod_path_unique", ["rendered_pod_path"]);

=head1 RELATIONS

=head2 distribution

Type: belongs_to

Related object: L<ThisPAN::Schema::Result::Distribution>

=cut

__PACKAGE__->belongs_to(
  "distribution",
  "ThisPAN::Schema::Result::Distribution",
  { id => "distribution" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 relationships_rel

Type: has_many

Related object: L<ThisPAN::Schema::Result::Relationship>

=cut

__PACKAGE__->has_many(
  "relationships_rel",
  "ThisPAN::Schema::Result::Relationship",
  { "foreign.module" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07039 @ 2014-03-28 11:47:34
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:9fU8qVrDGQAOHY9iiPjE7g


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
