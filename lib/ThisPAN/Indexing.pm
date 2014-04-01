package ThisPAN::Indexing;

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use File::Copy;
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

has 'mirror' => (is => 'ro',
                 isa => sub { blessed($_[0]) and $_[0]->isa('URI') },
                 default => sub { URI->new(q{http://www.cpan.org/}) },
                 coerce => sub {
                     unless (blessed($_[0])) {
                         return URI->new($_[0])
                     }
                 });
has 'base_url' => (is => 'ro',
                   required => 1);
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
    foreach my $hook (qw/perl_indexed new_distribution_indexed new_module_indexed missing_dependency/) {
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
    my @modules = File::Find::Rule->file->name('*.pm')->in(dir($payload->{extracted_at}, 'lib'));

    foreach my $module (@modules) {
        my $pod_renderer = Pod::Simple::XHTML->new;
        # this is going to be inserted in a larger document
        $pod_renderer->html_header('');
        $pod_renderer->html_footer('');
        # http://localhost:5000/module/MODULENAME
        $pod_renderer->perldoc_url_prefix($self->base_url . 'module/');
        $pod_renderer->output_string(\my $html);
        $pod_renderer->parse_file($module);
        # from tmp9380439/lib/Foo/Bar.pm to Foo/Bar.html
        $module =~ s/\.pm$/.html/;
        $module = file($module)->relative(dir($payload->{extracted_at}, 'lib'));
        # dist-data/Foo-Bar/pod/Foo/Bar.html
        my $rendered_pod_path = $dist_object->base_pod_dir($self->workdir)->file($module);
        $rendered_pod_path->parent->mkpath;
        my $fh = $rendered_pod_path->openw;
        $fh->print($html);
        $fh->close;
    }

    # mark dist as new so that we can build its relationships
    $self->new_dists_this_run->{$dist_object->name} = {
        prereqs => $payload->{prereqs} };

    $self->dist_index_by_name->{$dist_object->name} = $dist_object;

}

sub hook_new_module_indexed {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, module

    my $filename = $payload->{module} . '.html';
    my $distribution_name = $payload->{distribution};

    my $distribution = $self->dist_index_by_name->{$distribution_name} //= $self->schema->resultset('Distribution')->find({ name => $distribution_name },
                                                                                                                          { key => 'name_unique' });
    unless ($distribution) {
        warn(sprintf(q{Trying to create module %s for missing distribution %s},
                     $payload->{module},
                     $distribution_name));
        return;
    }
    my $rendered_pod_path = $distribution->base_pod_dir($self->workdir)->file(split('::', $filename));
    eval {
        $distribution->find_or_create_related('modules',
                                              { name => $payload->{module},
                                                rendered_pod_path => -e $rendered_pod_path ? $rendered_pod_path->relative($self->workdir)->stringify : undef },
                                              { key => 'name_unique' });
    };
    if (my $error = $@) {
        warn(sprintf(q{While trying to insert module %s for dist %s: %s},
                     $payload->{module},
                     $distribution_name,
                     $error));
    }
}

sub hook_missing_dependency {
    my ($self, $graphmaker, $hook_name, $payload) = @_;
    # payload has keys: module
    warn(sprintf(q{Missing dependency: %s},
                 $payload->{module}));
}

sub run {
    my $self = shift;
    my $graph;
    $self->schema->txn_do(sub {
        $self->graph_factory->full_dependency_graph;
        $self->_create_new_links;
        $graph = $self->graph_factory->grow_graph;
        if ($self->has_graph_factory_save_file) {
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
                        warn("Can't find dist dependency $dist_of_dependency for $distribution!");
                        next;
                    }
                    my $module_object = $self->module_index_by_name->{$dependency} //= $self->schema->resultset('Module')->find({ name => $dependency });
                    unless ($module_object) {
                        warn("Can't find module dependency $dependency for $distribution!");
                        next;
                    }
                    say(sprintf(q{Now linking %s to %s through %s},
                                $distribution, $dist_of_dependency, $dependency));
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
