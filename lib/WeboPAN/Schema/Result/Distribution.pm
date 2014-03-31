use utf8;
package WeboPAN::Schema::Result::Distribution;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

WeboPAN::Schema::Result::Distribution

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

=head1 TABLE: C<distribution>

=cut

__PACKAGE__->table("distribution");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 name

  data_type: 'varchar'
  is_nullable: 0

=head2 version

  data_type: 'varchar'
  is_nullable: 1

=head2 changes_path

  data_type: 'varchar'
  is_nullable: 1

=head2 dependency_json_path

  data_type: 'varchar'
  is_nullable: 1

=head2 metadata_json_blob

  data_type: 'varchar'
  is_nullable: 0

=head2 tarball_path

  data_type: 'varchar'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "name",
  { data_type => "varchar", is_nullable => 0 },
  "version",
  { data_type => "varchar", is_nullable => 1 },
  "changes_path",
  { data_type => "varchar", is_nullable => 1 },
  "dependency_json_path",
  { data_type => "varchar", is_nullable => 1 },
  "metadata_json_blob",
  { data_type => "varchar", is_nullable => 0 },
  "tarball_path",
  { data_type => "varchar", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<changes_path_unique>

=over 4

=item * L</changes_path>

=back

=cut

__PACKAGE__->add_unique_constraint("changes_path_unique", ["changes_path"]);

=head2 C<dependency_json_path_unique>

=over 4

=item * L</dependency_json_path>

=back

=cut

__PACKAGE__->add_unique_constraint("dependency_json_path_unique", ["dependency_json_path"]);

=head2 C<name_unique>

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->add_unique_constraint("name_unique", ["name"]);

=head2 C<tarball_path_unique>

=over 4

=item * L</tarball_path>

=back

=cut

__PACKAGE__->add_unique_constraint("tarball_path_unique", ["tarball_path"]);

=head1 RELATIONS

=head2 modules

Type: has_many

Related object: L<WeboPAN::Schema::Result::Module>

=cut

__PACKAGE__->has_many(
  "modules",
  "WeboPAN::Schema::Result::Module",
  { "foreign.distribution" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 relationship_children

Type: has_many

Related object: L<WeboPAN::Schema::Result::Relationship>

=cut

__PACKAGE__->has_many(
  "relationship_children",
  "WeboPAN::Schema::Result::Relationship",
  { "foreign.child" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 relationship_parents

Type: has_many

Related object: L<WeboPAN::Schema::Result::Relationship>

=cut

__PACKAGE__->has_many(
  "relationship_parents",
  "WeboPAN::Schema::Result::Relationship",
  { "foreign.parent" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07039 @ 2014-03-28 10:54:03
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:c2j5SV1QGibj74MS47RswQ

use JSON -convert_blessed_universally;
my $json = JSON->new;
$json->allow_blessed(1);
$json->convert_blessed(1);
__PACKAGE__->inflate_column('metadata_json_blob', {
    inflate => sub { $json->decode(shift) },
    deflate => sub { $json->encode(shift) },
});

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
