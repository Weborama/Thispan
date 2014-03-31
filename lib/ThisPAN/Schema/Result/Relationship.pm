use utf8;
package ThisPAN::Schema::Result::Relationship;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

ThisPAN::Schema::Result::Relationship

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

=head1 TABLE: C<relationship>

=cut

__PACKAGE__->table("relationship");

=head1 ACCESSORS

=head2 parent

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 child

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 module

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 phase

  data_type: 'varchar'
  is_nullable: 0

=head2 type

  data_type: 'varchar'
  is_nullable: 0

=head2 version

  data_type: 'varchar'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "parent",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "child",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "module",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "phase",
  { data_type => "varchar", is_nullable => 0 },
  "type",
  { data_type => "varchar", is_nullable => 0 },
  "version",
  { data_type => "varchar", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</parent>

=item * L</child>

=item * L</module>

=item * L</phase>

=back

=cut

__PACKAGE__->set_primary_key("parent", "child", "module", "phase");

=head1 RELATIONS

=head2 child

Type: belongs_to

Related object: L<ThisPAN::Schema::Result::Distribution>

=cut

__PACKAGE__->belongs_to(
  "child",
  "ThisPAN::Schema::Result::Distribution",
  { id => "child" },
  { is_deferrable => 0, on_delete => "RESTRICT", on_update => "CASCADE" },
);

=head2 module

Type: belongs_to

Related object: L<ThisPAN::Schema::Result::Module>

=cut

__PACKAGE__->belongs_to(
  "module",
  "ThisPAN::Schema::Result::Module",
  { id => "module" },
  { is_deferrable => 0, on_delete => "RESTRICT", on_update => "CASCADE" },
);

=head2 parent

Type: belongs_to

Related object: L<ThisPAN::Schema::Result::Distribution>

=cut

__PACKAGE__->belongs_to(
  "parent",
  "ThisPAN::Schema::Result::Distribution",
  { id => "parent" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07039 @ 2014-03-28 11:55:16
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:vfxH1m3BfuzwFrWXbJZ2wA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
