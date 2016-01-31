package ThisPAN::Indexing;

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use File::Copy;
use File::Find::Rule;
use Log::Any;
use Moo;
use Path::Class;
use Scalar::Util qw/blessed/;
use Storable qw/retrieve/;
use ThisPAN::DependencyGraph;
use ThisPAN::Schema;
use URI;

use Pod::Simple::XHTML;

{ no warnings 'redefine';
  # force detection of code as Perl -- most interesting verbatim
  # blocks are SYNOPSIS and method usage examples
  sub Pod::Simple::XHTML::start_Verbatim {
      $_[0]{'scratch'} = '<pre><code class="language-perl">';
  }
}

has 'config' => (is => 'ro',
                 default => sub { {} });
has 'mirror' => (is => 'ro',
                 isa => sub { blessed($_[0]) and $_[0]->isa('URI') },
                 default => sub { URI->new(q{http://www.cpan.org/}) },
                 coerce => sub {
                     unless (blessed($_[0])) {
                         return URI->new($_[0])
                     }
                 });
has 'logger' => (is => 'ro',
                 lazy => 1,
                 default => sub { Log::Any->get_logger(category => blessed(shift)) });
has 'workdir' => (is => 'ro',
                  required => 1);
has 'lock_file' => (is => 'ro');
has 'graph_factory' => (is => 'ro',
                        writer => '_set_graph_factory');
has 'graph_factory_save_file' => (is => 'ro',
                                  predicate => 1);
has 'schema' => (is => 'ro',
                 required => 1);
has 'module_index_by_name' => (is => 'ro',
                               default => sub { {} });
has 'dist_index_by_name' => (is => 'ro',
                             default => sub { {} });
has 'new_dists_this_run' => (is => 'ro',
                             default => sub { {} });

sub BUILD {
    my $self = shift;
    # ... grab lock
    if ($self->has_graph_factory_save_file
        and -e $self->graph_factory_save_file) {
        $self->_set_graph_factory($self->load_graph_factory);
    } else {
        $self->_set_graph_factory($self->build_graph_factory);
    }
    foreach my $hook (qw/perl_indexed new_distribution_indexed new_module_indexed missing_dependency dist_changed module_changed/) {
        # attach to all known hooks -- update this if new hooks appear
        if (my $callback = $self->can("hook_$hook")) {
            $self->graph_factory->attach_hook($hook,
                                              sub { $callback->($self, @_) });
        }
    }
    if ($self->has_graph_factory_save_file
        and -e $self->graph_factory_save_file) {
        # can't do this in load_graph_factory, because we plan on
        # adding hooks to the reindexing, and we need an instance to
        # attach hooks to
        $self->graph_factory->reindex;
    }
}

sub DEMOLISH {
    my $self = shift;
    # ... release lock
}

sub load_graph_factory {
    my $self = shift;
    my $graphmaker = retrieve($self->graph_factory_save_file)
        or croak("Can't restore graph factory from save file: unspecified I/O error");
    unless ($graphmaker->mirror eq $self->mirror) {
        croak("Can't restore graph factory from save file with different mirror!");
    }
    return $graphmaker;
}

sub build_graph_factory { # NOT A BUILDER
    my $self = shift;
    return ThisPAN::DependencyGraph->new(mirror => $self->mirror);
}

# override us!
sub hook_perl_indexed {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, tarball, extracted_at, version,
    # metadata, prereqs
    # TODO: handle upgrades and downgrades
    $self->schema->resultset('Distribution')->create(
        { name => $payload->{distribution},
          version => $payload->{version},
          changes_path => undef,
          metadata_json_blob => {},
          tarball_path => URI->new_abs('authors/id/' . $payload->{tarball}, $self->mirror) });
}

sub hook_new_distribution_indexed {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, tarball, extracted_at, version,
    # metadata, prereqs

    my $distribution = $payload->{distribution};

    my $dist_object = $self->schema->resultset('Distribution')->find_or_new(
        { name => $distribution },
        { key => 'name_unique' });

    # these happen regardless of downgrade/upgrade/new
    $dist_object->version($payload->{version});
    $dist_object->metadata_json_blob($payload->{metadata});
    $dist_object->tarball_path(URI->new_abs('authors/id/' . $payload->{tarball}, $self->mirror));
    $dist_object->base_dir($self->workdir)->mkpath;

    # copy extracted_at/(Changes|CHANGES)
    my $changes_path;
    if (-e $payload->{extracted_at}->file('Changes')) {
        copy($payload->{extracted_at}->file('Changes'),
             file($self->workdir, $distribution, 'Changes'));
        $changes_path = file($distribution, 'Changes');
    } elsif (-e $payload->{extracted_at}->file('CHANGES')) {
        copy($payload->{extracted_at}->file('CHANGES'),
             file($self->workdir, $distribution, 'Changes'));
        $changes_path = file($distribution, 'Changes');
    }

    $dist_object->changes_path($changes_path ? $changes_path->stringify : undef);

    if ($dist_object->in_storage) {
        $dist_object->update;
    } else {
        $dist_object->insert;
    }

    # find module files and render PODs -- TODO: find script files and
    # POD files.  POD files at least are indexed so that should be
    # easier -- NOTE: this has to be done here instead of
    # "new_module_indexed" because we trust the package index over the
    # distribution metadata or find -iname '*.pm' for finding modules,
    # so by the time our search progresses to a given module we don't
    # necessarily have the unpacked tarball anymore
    my @modules = File::Find::Rule->file->name('*.pm', '*.pod')->in(dir($payload->{extracted_at}, 'lib'));

    foreach my $module (@modules) {
        my $original_module_path = $module;
        my $pod_renderer = Pod::Simple::XHTML->new;
        # this is going to be inserted in a larger document
        $pod_renderer->html_header('');
        $pod_renderer->html_footer('');
        # all URLs relative to this document's own
        $pod_renderer->perldoc_url_prefix('../module/');
        $pod_renderer->output_string(\my $html);
        $pod_renderer->parse_file($module);
        # from tmp9380439/lib/Foo/Bar.pm to Foo/Bar.html
        $module =~ s/\.p(m|od)$/.html/;
        $module = file($module)->relative(dir($payload->{extracted_at}, 'lib'));
        # dist-data/Foo-Bar/pod/Foo/Bar.html
        my $rendered_pod_path = $dist_object->base_pod_dir($self->workdir)->file($module);
        $rendered_pod_path->parent->mkpath;
        my $fh = $rendered_pod_path->openw;
        $fh->print($html);
        $fh->close;
        if ($original_module_path =~ m/\.pod$/) {
            # not indexed by pinto, so won't fire new_module_indexed
            # naturally.
            my $module_name = $module;
            $module_name =~ s/\.html$//;
            $module_name =~ s{/}{::}g;
            $self->hook_new_module_indexed($graphmaker, 'new_module_indexed',
                                           { distribution => $dist_object->name,
                                             module => $module_name });
        }
    }

    # mark dist as new so that we can build its relationships
    $self->new_dists_this_run->{$dist_object->name} = {
        prereqs => $payload->{prereqs} };

    $self->dist_index_by_name->{$dist_object->name} = $dist_object;

    return $dist_object;

}

sub hook_new_module_indexed {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, module

    my $filename = $payload->{module} . '.html';
    my $distribution_name = $payload->{distribution};

    my $distribution = $self->dist_index_by_name->{$distribution_name} //= $self->schema->resultset('Distribution')->find({ name => $distribution_name },
                                                                                                                          { key => 'name_unique' });
    unless ($distribution) {
        $self->logger->errorf(q{While trying to find or create module %s for dist %s: distribution is not in database},
                              $payload->{module},
                              $distribution_name);
        return;
    }
    my $rendered_pod_path = $distribution->base_pod_dir($self->workdir)->file(split('::', $filename));
    eval {
        $self->schema->resultset('Module')->find_or_create(
            { name => $payload->{module},
              distribution => $distribution->id,
              rendered_pod_path => -e $rendered_pod_path ? $rendered_pod_path->relative($self->workdir)->stringify : undef },
            { key => 'name_unique' });
    };
    if (my $error = $@) {
        $self->logger->errorf(q{While trying to find or create module %s for dist %s: %s},
                              $payload->{module},
                              $distribution_name,
                              $error);
        return;
    }

}

sub hook_missing_dependency {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: module
    $self->logger->warningf(q{Missing dependency: %s},
                            $payload->{module});
}

sub hook_dist_changed {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: dist_name
    $self->logger->infof(q{Distribution has changed: %s},
                         $payload->{dist_name});
}

sub hook_module_changed {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: module_name, maybe old_module, maybe new_module
    $self->logger->warningf(q{Module has changed: %s},
                            $payload->{module_name});
}

sub run {
    my $self = shift;
    my $graph;
    $self->schema->txn_do(sub {
        $self->graph_factory->full_dependency_graph;
        $self->_create_new_links;
        $graph = $self->graph_factory->grow_graph;
        if ($self->has_graph_factory_save_file) {
            $self->logger->infof(q{Writing graph file to %s},
                                 $self->graph_factory_save_file);
            $self->graph_factory->serialize($self->graph_factory_save_file);
        }
                          });
    return $graph;
}

sub _create_new_links {
    my $self = shift;

    my $graphmaker = $self->graph_factory;

    foreach my $distribution (keys %{$self->new_dists_this_run}) {

        # that's { prereqs => PREREQS }
        my $postprocess_job = $self->new_dists_this_run->{$distribution};

        my $dist_object = $self->dist_index_by_name->{$distribution} //= $self->schema->resultset('Distribution')->find({ name => $distribution },
                                                                                                                        { key => 'name_unique' });

        # link the dists together

        foreach my $prereq_phase (@{$graphmaker->requirement_phases}) {
            foreach my $prereq_type (@{$graphmaker->requirement_types}) {
                my $prereqs = $postprocess_job->{prereqs}->requirements_for($prereq_phase, $prereq_type)->as_string_hash;
                foreach my $dependency (keys %{$prereqs}) {
                    my $dist_of_dependency = $graphmaker->modules_visited->{$dependency};
                    next unless $dist_of_dependency;
                    my $dep_object = $self->dist_index_by_name->{$dist_of_dependency} //= $self->schema->resultset('Distribution')->find({ name => $dist_of_dependency },
                                                                                                                                         { key => 'name_unique' });
                    unless ($dep_object) {
                        $self->logger->errorf(q{Distribution %s depends on distribution %s but it cannot be found in database},
                                      $distribution, $dist_of_dependency);
                        next;
                    }
                    my $module_object = $self->module_index_by_name->{$dependency} //= $self->schema->resultset('Module')->find({ name => $dependency });
                    unless ($module_object) {
                        $self->logger->errorf(q{Distribution %s depends on module %s but it cannot be found in database},
                                      $distribution, $dependency);
                        next;
                    }
                    $self->logger->infof(q{Adding relationship: %s depends on %s because %s is required for %s},
                                         $distribution, $dist_of_dependency,
                                         $dependency, $prereq_phase);
                    # TODO handle relationships dropped or moved from
                    # phase to phase
                    $self->schema->resultset('Relationship')->find_or_create(
                        { parent => $dist_object->id,
                          child => $dep_object->id,
                          module => $module_object->id,
                          phase => $prereq_phase,
                          type => $prereq_type,
                          version => $prereqs->{$dependency} });
                }
            }
        }

    }
}

1;
__END__
=pod

=head1 NAME

ThisPAN::Indexing -- Indexing library for ThisPAN

=head1 SYNOPSIS

  use ThisPAN::Indexing;
  my $indexer = ThisPAN::Indexing->new(
      # mirror => 'http://example.com/cpan-mirror',
      mirror => 'file:///path/to/mirror',
      workdir => 'path/to/writable/directory',
      graph_factory_save_file => 'path/to/writable/file.storable',
      schema => ThisPAN::Schema->connect(...));
  my $graph = $indexer->run;
  foreach my $dist ($graph->vertices) {
      # do your thing
  }

=head1 DESCRIPTION

L<ThisPAN::Indexing> consumes events emitted from walking a dependency
graph with L<ThisPAN::DependencyGraph> and populates a database with
them.

L<ThisPAN::Indexing> is a Moo class.

=head2 WHAT DOES IT DO

The indexer...

=over 4

=item * inserts and updates distributions, modules, and dependency
relationships in database

=item * generates POD from the files found in a tarball

=item * extracts the Changes file

=back

=head1 ATTRIBUTES

=head2 dist_index_by_name

(read-only hashref of L<ThisPAN::Schema::Result::Module> instances)

During the run of the indexer, distributions fetched from database are
indexed by their name here.  This is purely a convenience for rapid
access; fortunately distribution rows are not updated much during an
indexing.

=head2 graph_factory

(read-only L<ThisPAN::DependencyGraph> instance, writer at
C<_set_graph_factory>)

The dependency walker is restored from file (see
C<graph_factory_save_file>) if possible, otherwise it is created from
scratch.  In either case, the indexer will (re-)attach several hooks
to it (see the L</HOOKS> section).

=head2 graph_factory_save_file

(read-only path to a Storable file)

If C<graph_factory_save_file> is set and exists, at construction time
the indexer will attempt to deserialize its contents (via
L<Storable>'s C<retrieve>) to build the C<graph_factory>.  If this
works, the indexer will additionally call the walker's C<reindex>
method.

If the attribute is set, at the end of the C<run> method, the indexer
will tell the walker to go serialize itself in this file.

If the attribute is not set, neither of these things will happen, and
the walker will start from scratch every time.

=head2 logger

(read-only lazy L<Log::Any> object)

Because this distribution is expected to run non-interactively (cron
jobs, daemon...), all log output, debug, etc. should go through this
object.  By default, it is a logger in the category C<CLASSNAME> where
C<CLASSNAME> is the name of the current instance's class (that is,
L<ThisPAN::Indexing> or a subclass thereof).

=head2 mirror

(read-only URI object, coerced from a string)

The URL to the mirror providing the tarballs, defaults to
"http://www.cpan.org".

=head2 module_index_by_name

(read-only hashref of L<ThisPAN::Schema::Result::Module> instances)

During the run of the indexer, modules fetched from database are
indexed by their name here.  This is purely a convenience for rapid
access; fortunately module rows are not updated much during an
indexing.

=head2 new_dists_this_run

(read-only hashref of unspecified data)

TODO: mark as private

=head2 schema

(read-only required L<ThisPAN::Schema> instance)

The database will contain distribution metadata, module metadata, and
distribution to distribution relationships.

=head2 workdir

(read-only required string)

The indexing process writes out a lot of files: Changes files,
rendered POD, and possibly the full dependency graph in JSON format if
you're using the example indexing script.  C<workdir> will be created
if it doesn't already exist.

=head1 METHODS

=head2 BUILD

The C<BUILD> method loads the dependency walker from a file, if
appropriate (see the C<graph_factory> and C<graph_factory_save_file>
attributes); otherwise it creates a brand new instance of
L<ThisPAN::DependencyGraph>.  In both cases it then installs all hooks
available (see L</HOOKS>).

When this feature is finally implemented, it will also grab a lock.

=head2 DEMOLISH

When this feature is finally implemented, this method will release the
lock grabbed by C<BUILD>.  Currently it does nothing special.

=head2 build_graph_factory

  $indexer->_set_graph_factory($self->build_graph_factory);

Builds a new L<ThisPAN::DependencyGraph> instance.  Not intended for
public consumption.

Despite the name, this is not the C<graph_factory> attribute's builder
method.

=head2 load_graph_factory

  $indexer->_set_graph_factory($self->load_graph_factory);

Deserializes and returns a L<ThisPAN::DependencyGraph> instance from
the file at C<graph_factory_save_file>.  Not intended for public
consumption.

=head2 run

  my $graph = $indexer->run;

This method starts a transaction in the schema, then builds the full
dependency graph (rebuilding only the changed parts as appropriate, if
the dependency walker has been restored from file).  In a post-process
phase (not through hooks -- this should probably be considered a bug),
it creates the relationships between distributions.  Finally it builds
a L<Graph> instance through the dependency walker, saves the walker to
file if appropriate, and closes the transaction.

If an unhandled exception happens at any time, the transaction is
rolled back.  The walker serialization happens as the very last step,
so if anything bad happens, the walker will also "revert" to its state
before indexing started.

=head1 HOOKS

After construction (during C<BUILD>, the indexer will attach callbacks
to all known hooks (currently: "dist_changed", "missing_dependency",
"module_changed", "new_distribution_indexed", "new_module_indexed" and
"perl_indexed").  This is done by checking if

  $callback = $self->can("hook_$hookname")

returns a value; if so,

  sub { $callback->($self, @_) }

is attached to the hook.  This means that the C<hook_*> methods in
this class (or your own subclass of this class) will run with the
following arguments:

=over 4

=item * the indexer instance

=item * the dependency walker instance

=item * the hook name, such as "perl_indexed"

=item * the payload provided by the dependency walker when firing the
hook; see the relevant documentation for L<ThisPAN::DependencyGraph>.

=back

Note that all six of the hooks mentioned have an implementation
already in this class, and that in most cases this implementation is
important for proper indexing.  If you wish to attach your own
callbacks, you should make sure you call the superclass' method with
SUPER.

  package OurPAN::Indexing::WithLucy;
  use Moo;
  extends 'ThisPAN::Indexing';
  sub hook_new_distribution_indexed {
      my $self = shift;
      my ($depwalker, undef, $payload) = @_;
      my $retval = $self->SUPER::hook_new_distribution_indexed(@_);
      # index the POD with Lucy here...
      return $retval;
  }

=head1 SEE ALSO

L<ThisPAN::DependencyGraph>, L<ThisPAN::Schema>

=head1 AUTHOR

Fabrice Gabolde <fgabolde@weborama.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Weborama.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.

=cut
