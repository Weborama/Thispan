package ThisPAN::DependencyGraph;

use strict;
use warnings;
use 5.010;
use Carp;
use autodie qw/:all/;
use utf8;

use Archive::Extract;
use CPAN::Meta;
use DateTime;
use File::Copy;
use File::Spec;
use File::Temp;
use Graph;
use HTTP::Tiny;
use IO::File;
use JSON;
use List::MoreUtils qw/uniq/;
use Log::Any;
use Module::CoreList 2.21;
use Params::Validate qw/:types validate/;
use Path::Class;
use Scalar::Util qw/blessed/;
use Storable qw/nstore/;
use Try::Tiny;
use URI;
use YAML;

use Moo;

has 'mirror' => (is => 'ro',
                 required => 1);
has 'workspace' => (is => 'rw',
                    clearer => 1,
                    lazy => 1,
                    default => sub { File::Spec->tmpdir });
has 'logger' => (is => 'ro',
                 lazy => 1,
                 clearer => 1,
                 default => sub { Log::Any->get_logger(category => blessed(shift)) });
has 'requirement_phases' => (is => 'ro',
                             default => sub { [qw/configure build test runtime/] });
has 'requirement_types' => (is => 'ro',
                            default => sub { [qw/requires/] });
has 'package_index' => (is => 'ro',
                        writer => '_set_package_index',
                        lazy => 1,
                        builder => 'fetch_and_build_package_index');
has 'dist_metadata' => (is => 'ro',
                        lazy => 1,
                        default => sub { { perl => { modules => [] } } });
has 'perl_tarball' => (is => 'ro',
                       lazy => 1,
                       builder => 'find_perl_tarball');
has 'perl_version' => (is => 'ro',
                       writer => '_set_perl_version');
has 'tarballs_visited' => (is => 'ro',
                           lazy => 1,
                           default => sub {
                               my $self = shift;
                               return { $self->perl_tarball => 'perl' } });
has 'modules_visited' => (is => 'ro',
                          default => sub { {} });
has 'hook_map' => (is => 'ro',
                   writer => '_set_hook_map',
                   default => sub { {} });

sub BUILD {
    my $self = shift;
    say "Checking " . $self->workspace;
    unless (-e $self->workspace) {
        $self->logger->infof(q{Creating workspace directory %s},
                             $self->workspace);
        dir($self->workspace)->mkpath;
    }
}

sub attach_hook {
    my ($self, $hook_name, $callback) = @_;
    push @{$self->hook_map->{$hook_name}}, $callback;
    return $self;
}

sub fire_hooks {
    my ($self, $hook_name, @args) = @_;
    foreach my $callback (@{$self->hook_map->{$hook_name} // []}) {
        $callback->($self, $hook_name, @args);
    }
    return $self;
}

sub serialize {
    my ($self, $filename) = @_;
    $self->_set_hook_map({});
    $self->clear_logger;
    $self->clear_workspace;
    nstore($self, $filename);
    return $filename;
}

sub fetch_file {
    my ($self, $url, $destination) = @_;
    $self->logger->infof(q{Fetching URL %s},
                        $url->as_string);
    if ($url->scheme eq 'http') {
        my $response = HTTP::Tiny->new->get($url);
        croak(sprintf(q{Could not fetch file at %s: %d %s},
                      $url, $response->{status}, $response->{reason}))
            unless $response->{success};
        my $content = $response->{content};
        my $fh;
        if ($destination) {
            $fh = IO::File->new($destination, 'w');
        } else {
            ($fh, $destination) = File::Temp::tempfile(UNLINK => 0,
                                                       DIR => $self->workspace);
        }
        $fh->print($content);
        $fh->close;
        # note the cheap stringification: because $destination might
        # be an object or a string, and Log::Any does its own
        # stringification
        $self->logger->infof(q{File has been fetched via HTTP to %s},
                             "$destination");
    } elsif ($url->scheme eq 'file') {
        (undef, $destination) = File::Temp::tempfile(UNLINK => 0,
                                                     DIR => $self->workspace)
            unless $destination;
        copy($url->file, $destination) or croak(sprintf(q{Could not copy file at %s: %s},
                                                        $url->file, $!));
        $self->logger->infof(q{File has been copied from %s to %s},
                             $url->file,
                             "$destination");
    } else {
        croak(sprintf(q{Not sure how to handle URI scheme '%s'},
                      $url->scheme));
    }
    return $destination;
}

sub parse_meta_json {
    my ($self, $metafile) = @_;
    my $meta_contents = try {
        JSON::decode_json(scalar $metafile->slurp);
    } catch {
        $self->logger->warningf(q{While trying to parse JSON metadata file %s: %s},
                                $metafile, $_);
        return;
    };
    return unless $meta_contents;
    # if ($meta_contents->{dynamic_config}) {
    #     warn "$metafile has dynamic_config set to a true value.\n";
    #     warn "Prereqs must be determined by running a build script.\n";
    #     return;
    # }
    $self->logger->infof(q{Valid JSON metadata file found at %s}, $metafile->stringify);
    return $meta_contents;
}

sub parse_meta_yaml {
    my ($self, $metafile) = @_;
    my $meta_contents = try {
        YAML::Load(scalar $metafile->slurp);
    } catch {
        $self->logger->warningf(q{While trying to parse YAML metadata file %s: %s},
                                $metafile, $_);
        return;
    };
    return unless $meta_contents;
    # if ($meta_contents->{dynamic_config}) {
    #     warn "$metafile has dynamic_config set to a true value.\n";
    #     warn "Prereqs must be determined by running a build script.\n";
    #     return;
    # }
    $self->logger->infof(q{Valid YAML metadata file found at %s}, $metafile->stringify);
    return $meta_contents;
}

sub run_configure_script {
    my ($self, $sandbox, $make_or_build_pl) = @_;
    my (undef, $tempfile) = File::Temp::tempfile(UNLINK => 0,
                                                 DIR => $self->workspace);
    $tempfile = file($tempfile)->absolute;

    try {
        local $ENV{PERL_MM_USE_DEFAULT} = 1;
        system("cd '$sandbox' && perl '$make_or_build_pl' > $tempfile 2>&1");
        unlink $tempfile;
        return 1;
    } catch {
        $self->logger->warningf(q{While trying to run build script %s: %s},
                                $make_or_build_pl->stringify, "$_");
        $self->logger->warningf(q{Logs have been kept at %s},
                                "$tempfile");
        return;
    } or return;
    $self->logger->infof(q{Executed configure script at %s}, $make_or_build_pl->stringify);
    return $self->parse_meta_json($sandbox->file('MYMETA.json'))
        || $self->parse_meta_yaml($sandbox->file('MYMETA.yml'));
}

sub looks_like_perl_tarball {
    my ($self, $tarball_path) = @_;
    if ($tarball_path =~ m{/perl-(5[\d.]+).tar.(gz|bz2)}) {
        return 1;
    }
    return;
}

sub find_perl_tarball {

    my $self = shift;

    foreach my $tarball (values %{$self->package_index}) {
        next unless $self->looks_like_perl_tarball($tarball);
        $self->_set_perl_version($1);
        $self->dist_metadata->{perl}->{version} = $self->perl_version;

        $self->fire_hooks('perl_indexed',
                          { distribution => 'perl',
                            tarball => $tarball,
                            version => $self->perl_version });

        return $tarball;
    }

}

sub fetch_and_build_package_index {

    my $self = shift;
    my $package_index_filename = $self->fetch_file(URI->new_abs('modules/02packages.details.txt.gz', $self->mirror));

    my $index_contents;

    my $index_archive = Archive::Extract->new(archive => $package_index_filename,
                                              type => 'gz');
    my (undef, $extracted_filename) = File::Temp::tempfile(UNLINK => 0,
                                                           DIR => $self->workspace);
    $self->logger->infof(q{Extracting package index %s to %s},
                         $package_index_filename, $extracted_filename);
    $index_archive->extract(to => $extracted_filename);
    unlink $package_index_filename;
    my $fh = IO::File->new($extracted_filename, 'r');

    my %index;

    # parse and transform 02packages.details.txt
    my $in_header = 1;
    $self->logger->info(q{Parsing extracted package index});
    while (my $line = $fh->getline) {
        chomp($line);
        if ($line =~ /^$/ and $in_header) {
            $in_header = 0;
            next;
        }
        next if $in_header;
        my ($module_name, $module_version, $path) = split(/\s+/, $line);
        $module_version = 0 if $module_version eq 'undef';
        my $dist_name = Path::Class::file($path)->basename;
        $dist_name =~ s/-[\d.]+(?:-TRIAL)?[^-]*$//;
        $index{$module_name} = $path;
    }

    $self->logger->info(q{Done parsing package index});

    $fh->close;
    unlink $extracted_filename;

    return \%index;

}

sub fetch_and_get_metadata {

    my $self = shift;
    my $module = shift
        or croak "fetch_and_get_metadata needs at least a module";

    my $uri = URI->new('authors/id/' . $self->package_index->{$module})->abs($self->mirror);

    my @path_parts = $uri->path_segments;
    my $filename = $path_parts[-1];

    my $container = Path::Class::tempdir(CLEANUP => 0,
                                         DIR => $self->workspace);

    # the tarball needs a filename with a proper extension otherwise
    # Archive::Extract gets confused
    my $tarball = $self->fetch_file($uri, $container->file($filename));

    my $dist_archive = Archive::Extract->new(archive => $tarball);
    $self->logger->infof(q{Extracting distribution tarball %s to %s},
                         $tarball->stringify, $container->stringify);
    $dist_archive->extract(to => $container);
    unlink $tarball;

    # done with the dist tarball, now we have an extracted directory
    # in $sandbox

    my @files_in_sandbox = $container->children(no_hidden => 1);
    my $sandbox;

    if (@files_in_sandbox == 1
        and $files_in_sandbox[0]->is_dir) {
        # properly extracted tarball.  pretend that's what we meant
        # all along.  if we don't go through here it means it was one
        # of these tarballs where everything is just at the root
        $self->logger->info(q{Tarball has a single directory in it, good.});
        $sandbox = $files_in_sandbox[0];
    } else {
        # El Cheapo cloning
        $self->logger->info(q{Tarball doesn't have a proper root directory, assuming jumble.});
        $sandbox = dir($container);
    }

    $self->logger->info('Looking for metadata files...');

    # deafening applause
    my $meta_contents =
                                                               -e $sandbox->file('META.json')   && $self->parse_meta_json($sandbox->file('META.json'))
        || $self->logger->info('No usable META.json file.') && -e $sandbox->file('META.yml')    && $self->parse_meta_yaml($sandbox->file('META.yml'))
        || $self->logger->info('No usable META.yml file.')  && -e $sandbox->file('Build.PL')    && $self->run_configure_script($sandbox, $sandbox->file('Build.PL')->absolute)
        || $self->logger->info('No usable Build.PL file.')  && -e $sandbox->file('Makefile.PL') && $self->run_configure_script($sandbox, $sandbox->file('Makefile.PL')->absolute)
        || $self->logger->info('No usable Makefile.PL file.') && undef;

    my $metadata = {};

    if ($meta_contents) {
        $metadata = CPAN::Meta->new($meta_contents, { lazy_validation => 1 });
    } else {
        $self->logger->warn('Impossible to determine prereqs!');
    }

    return [ $sandbox, $container, $metadata ];

}

sub full_dependency_graph {

    my $self = shift;
    my %args = validate(@_,
                        { filter_with_regex => { default => undef } });

    $self->logger->info('Starting to build full dependency graph.');
    if ($self->perl_tarball) {
        $self->logger->infof(q{Perl tarball appears to be %s},
                             $self->perl_tarball);
    } else {
        $self->logger->warningf(q{Couldn't find a Perl tarball.});
    }

    foreach my $module (keys %{$self->package_index}) {

        next if exists $self->modules_visited->{$module};
        next unless (not $args{filter_with_regex}
                     or $module =~ $args{filter_with_regex});
        $self->logger->infof(q{Checking dependency chain for module %s},
                             $module);
        $self->module_dependency_graph($module,
                                       %args);

    }

    return $self;

}

sub module_dependency_graph {

    my $self = shift;
    my $starting_module = shift;
    my %args = validate(@_,
                        { filter_with_regex => { default => undef } });

    my @all_modules;
    push @all_modules, $starting_module;

    # Note that we are not using the "provides" field from the
    # metadata.  It is optional, unlike being indexed in 02packages.

    MODULE:
    while (my $this_module = shift @all_modules) {

        next if exists $self->modules_visited->{$this_module};

        my $tarball_path = $self->package_index->{$this_module};

        if (not $tarball_path) {

            # Pinto does not add an entry in the index for all modules
            # from core.  Test if this is the case, or if we're really
            # missing a dependency on the mirror.
            if (Module::CoreList->first_release($this_module)
                and version->parse(Module::CoreList->first_release($this_module))
                  <= version->parse($self->perl_version)) {
                # it's in core.  proceed, citizen
                $self->logger->infof(q{Skipping %s which is a core module (determined from Module::CoreList)},
                                     $this_module);
                $self->modules_visited->{$this_module} = 'perl';
                $tarball_path = $self->perl_tarball;
            } else {
                # missing dependency ermahgerd!
                $self->modules_visited->{$this_module} = undef;
                $self->fire_hooks('missing_dependency', { module => $this_module });
                next MODULE;
            }

        } elsif ($self->looks_like_perl_tarball($tarball_path)) {

            $self->logger->infof(q{Skipping %s which is a core module (provided by the Perl tarball)},
                                 $this_module);
            $self->modules_visited->{$this_module} = 'perl';
            next MODULE;

        } elsif (not $self->tarballs_visited->{$tarball_path}) {

            # if not already done, create the vertex in the dependency
            # graph.  we track advancement by tarball instead of dist
            # because this way we save having to unpack the tarball to
            # check what dist it provides
            my ($sandbox_path, $container_path, $metadata) = @{$self->fetch_and_get_metadata($this_module)};

            if (%{$metadata}) {

                $self->dist_metadata->{$metadata->name} = {
                    tarball => $tarball_path,
                    version => $metadata->version,
                    date_index => DateTime->now,
                    modules => [ ],
                    prereqs => $metadata->effective_prereqs };

                my $merged_prereqs = $metadata->effective_prereqs->merged_requirements(
                    $self->requirement_phases, $self->requirement_types);

                foreach my $required_module ($merged_prereqs->required_modules) {
                    if (not exists $self->modules_visited->{$required_module}
                        and not (defined $args{filter_with_regex}
                                 and $required_module !~ $args{filter_with_regex})) {
                        # unless dependency already visited, or not
                        # interesting to us, add it to the list of
                        # modules we still need to process
                        push @all_modules, $required_module;
                    }
                }

                $self->fire_hooks('new_distribution_indexed',
                                  { distribution => $metadata->name,
                                    tarball => $tarball_path,
                                    extracted_at => $sandbox_path,
                                    version => $metadata->version,
                                    metadata => $metadata,
                                    prereqs => $metadata->effective_prereqs });

                # map tarballs to the distribution contained, and mark
                # them as already analyzed
                $self->tarballs_visited->{$tarball_path} = $metadata->name;

            } else {

                $self->dist_metadata->{$tarball_path} = {
                    tarball => $tarball_path,
                    version => 0,
                    date_index => DateTime->now,
                    modules => [ ],
                    prereqs => CPAN::Meta::Prereqs->new({}) };

                $self->tarballs_visited->{$tarball_path} = $tarball_path;

            }

            # clean up our messes
            $container_path->rmtree;

        }

        # add current module to list of modules provided by its distribution
        $self->logger->infof('Adding module %s to distribution %s',
                             $this_module,
                             $self->tarballs_visited->{$tarball_path});
        push @{$self->dist_metadata->{$self->tarballs_visited->{$tarball_path}}->{modules}}, $this_module;

        # mark current module as processed, and set its parent distribution
        $self->modules_visited->{$this_module} = $self->tarballs_visited->{$tarball_path};

        $self->fire_hooks('new_module_indexed',
                          { distribution => $self->modules_visited->{$this_module},
                            module => $this_module });

    }

    return $self;

}

sub grow_graph {

    my $self = shift;

    my $graph = Graph->new(directed => 1);
    $graph->add_vertex('perl');

    # add all dists as vertices
    $graph->add_vertices(keys %{$self->dist_metadata});

    foreach my $distribution (keys %{$self->dist_metadata}) {
        # now we have all vertices, build edges from dep to dep
        # relationships.
        next if $distribution eq 'perl';
        foreach my $requirement_phase (@{$self->requirement_phases}) {
            foreach my $requirement_type (@{$self->requirement_types}) {
                my $prereqs = $self->dist_metadata->{$distribution}->{prereqs}->requirements_for($requirement_phase, $requirement_type)->as_string_hash;
                foreach my $module (keys %{$prereqs}) {
                    if ($self->modules_visited->{$module}) {
                        # from, to, attribute name, attribute data
                        $graph->set_edge_attribute(
                            $distribution,
                            $self->modules_visited->{$module},
                            'dep_metadata',
                            { phase => $requirement_phase,
                              type => $requirement_type,
                              version_range => $prereqs->{$module} });
                    } else {
                        # no value?  missing dependency.
                        if ($graph->has_vertex_attribute($distribution, 'missing_deps')) {
                            my @existing_missing_deps = @{$graph->get_vertex_attribute($distribution, 'missing_deps')};
                            $graph->set_vertex_attribute($distribution, 'missing_deps', [ uniq(@existing_missing_deps, $module) ]);
                        } else {
                            $graph->set_vertex_attribute($distribution, 'missing_deps', [ $module ]);
                        }
                    }
                }
            }
        }
    }

    return $graph;

}

sub reindex {

    my $self = shift;

    my $new_package_index = $self->fetch_and_build_package_index;

    my %modules_changed;

    foreach my $new_module (keys %{$new_package_index}) {

        if (not $self->package_index->{$new_module}
            or $self->package_index->{$new_module} ne $new_package_index->{$new_module}) {

            # modules that are not in the current package index are
            # added, modules that are in the current package index but
            # with a different tarball path are updated
            $modules_changed{$new_module}++;
            $self->fire_hooks('module_changed', {
                module => $new_module,
                (old_module => $self->package_index->{$new_module}) x!! $self->package_index->{$new_module},
                new_module => $new_package_index->{$new_module} });

        }

    }

    foreach my $old_module (keys %{$self->package_index}) {

        # modules that are in the current package index but not the
        # new one are removed
        next if exists $new_package_index->{$old_module};
        $modules_changed{$old_module}++;
        $self->fire_hooks('module_changed', {
            module => $old_module,
            old_module => $self->package_index->{$old_module} });

    }

    # three indexes/caches must be partially invalidated:
    # dist_metadata (map of dist names to metadata), tarballs_visited
    # (map of tarball paths to dist names), and modules_visited (map
    # of module names to parent dist names)

    my @dists_changed;

    foreach my $module_changed (keys %modules_changed) {
        my $dist = $self->modules_visited->{$module_changed};
        next unless $dist;
        push @dists_changed, $dist;
        $self->fire_hooks('dist_changed', { dist_name => $dist });
    }

    delete @{$self->dist_metadata}{@dists_changed};

    my @tarballs_changed = grep { defined $_ } map { $self->package_index->{$_} } keys %modules_changed;
    delete @{$self->tarballs_visited}{@tarballs_changed};

    delete @{$self->modules_visited}{keys %modules_changed};

    $self->_set_package_index($new_package_index);

    return $self;

}

1;
__END__
=pod

=head1 NAME

Weborama::CPANTools::DependencyGraph -- Build a dependency graph for a single module or the whole mirror

=head1 SYNOPSIS

  use Weborama::CPANTools::DependencyGraph;
  my $graphmaker = Weborama::CPANTools::DependencyGraph->new(
      mirror => 'http://...');
  my $graph = $graphmaker->module_dependency_graph('Acme::Weborama');
  # or --
  my $graph = $graphmaker->full_dependency_graph(filter_with_regex => qr/^Weborama/);
  my @flattened_tree;
  foreach my $vertex ($graph->vertices) {
      # the graph built is directed, distribution to dependency
      push @flattened_tree, {
          name => $vertex, # dist name
          imports => [ $graph->successors($vertex) ],
      };
  }

=head1 DESCRIPTION

This module is responsible for building distribution-to-distribution
dependency graphs.

You can serialize the object as-is (with a serializer/deserializer
that supports objects, anyway) to cache the results of the
computations done so far.  Initially, there was no way to do partial
reindexes and so the best way to cope with a nontrivial change on the
mirror (upgrades with new dependencies, downgrades, deletions) was to
trash the serialized object and start anew.  However, all current
versions of this module support partial reindexing (at the cost of not
maintaining the dependency graph, but regenerating it every time from
a flat data structure).  You probably won't ever see the old code in
action unless you checkout very old changesets.

L<ThisPAN::DependencyGraph> is a Moo class.

=head2 THE DEPENDENCIES GRAPH

The interesting dependency chain data is mainly available as a
directed L<Graph>.  While it should theoretically be a DAG, acyclicity
is not guaranteed (e.g. Foo v2 depends on Bar v1 depends on Foo v1
which is in core).

The graph's vertices are distribution names, not modules.  This is
because, while dependencies are on modules, they are always expressed
by a distribution as a whole.

Vertices can have a single attribute, "missing_deps", whose value will
be an arrayref of required modules that are not listed in the package
index.

The graph's edges are directed from distribution to dependency, where
"dependency" is understood to mean "parent distribution of a required
module".  While this should mean that a distribution can have multiple
edges to the same distribution (e.g. requiring C<Acme::Foo::Bar> and
C<Acme::Foo::Baz>), in practice this is not the case yet.  This is a
bug, since it means you cannot count on the dependency metadata being
correct.

Edges can have a single attribute, "dep_metadata", whose value will be
a hashref with the following keys:

=over 4

=item phase

one of C<configure>, C<runtime>, C<build>, C<test> or C<develop>

=item type

one of C<requires>, C<recommends>, C<suggests> or C<conflicts>

=item version_range

a string expressing a required version range, as returned by
C<CPAN::Meta::Requirements>'s C<as_string_hash> method

=back

=head1 ATTRIBUTES

=head2 dist_metadata

(read-only data structure)

This attribute contains a map of distribution metadata keyed by
distribution name.  The values are hashrefs with the following keys
and values:

=over 4

=item tarball

Path to distribution tarball on the mirror,
e.g. F<F/FO/FOO/FooBar-0.018.tar.gz>.

=item version

Version number of the distribution, as a L<version> object.

=item date_index

Date the distribution was indexed by L<ThisPan>, as a L<DateTime>
object.

=item modules

Arrayref of module names.

=item prereqs

All the prerequisites for this distribution, as a
L<CPAN::Meta::Prereqs> object.

=back

Only distributions that have been encountered in the process of
walking the dependency graph will be represented here.  Distributions
may disappear after C<reindex> has been called, if appropriate.

=head2 hook_map

(read-only hashref of coderefs)

TODO: make this attribute private

Note that this attribute is not serialized by the C<serialize> method
because many serializers do not support coderefs.

=head2 logger

(read-only lazy L<Log::Any> object)

Because this distribution is expected to run non-interactively (cron
jobs, daemon...), all log output, debug, etc. should go through this
object.  By default, it is a logger in the category C<CLASSNAME> where
C<CLASSNAME> is the name of the current instance's class (that is,
L<ThisPAN::DependencyGraph> or a subclass thereof).

=head2 mirror

(read-only required URI object)

The URL to the mirror providing the tarballs.

=head2 modules_visited

(read-only hashref of strings)

Map of module names to their parent distribution names.

Only modules that have been encountered in the process of walking the
dependency graph will be represented here.  Modules may disappear
after C<reindex> has been called, if appropriate.

=head2 package_index

(read-only hashref of strings)

Map of module names to distribution tarball paths on the mirror,
obtained straight from F<modules/02packages.details.txt.gz>.  This
attribute is updated by a call to C<reindex>.

=head2 perl_tarball

(read-only lazy string)

The path to the Perl tarball, found in the index.  This attribute's
builder also sets C<perl_version>, so if you provide it manually, make
sure to also provide C<perl_version>.

=head2 perl_version

(read-only string, mutator at C<_set_perl_version>)

Version number extracted from the Perl tarball path in the index.
This is set by the builder method for C<perl_tarball>.

=head2 requirement_phases

(read-only arrayref of strings)

What phases should be considered for the dependency walk.  By default,
this is an arrayref containing the strings "configure", "build",
"test" and "runtime".  "develop" is also a valid phase.

=head2 requirement_types

(read-only arrayref of strings)

What dependency types should be considered for the dependency walk.
By default, this is an arrayref containing the string "requires".
"recommends", "suggests" and "conflicts" are also valid types.

Note that currently this module will not treat "conflicts" prereqs
specially, which is probably not what you need.

=head2 tarballs_visited

(read-only hashref of strings)

Map of tarball paths (F<F/FO/FOO/FooBar-0.018.tar.gz>) to distribution
names.

Only tarballs that have been encountered in the process of walking the
dependency graph will be represented here.  Tarballs may disappear
after C<reindex> has been called, if appropriate.

=head1 METHODS

=head2 attach_hook

  $depgraph->attach_hook('new_distribution_indexed', sub { ... });

Add a coderef to be called during a dependency walk.  The coderef will
be given an argument list containing the L<ThisPAN::DependencyGraph>
instance, the hook name, and a payload (usually a hashref) with
variable contents.

=head2 fetch_and_build_package_index

Builder for C<package_index>, and called to build a fresh package
index when C<reindex> is called.

=head2 fetch_and_get_metadata

TODO: make this private.

=head2 fetch_file

  $depgraph->fetch_file($url, $destination);

Fetches the URL provided and writes it to disk.  The URL may be an
HTTP URL, in which case L<HTTP::Tiny> will be used, or a file URL, in
which case we simply copy the file over with L<File::Copy>.

=head2 find_perl_tarball

Builder for C<perl_tarball>, and sets C<perl_version>.

=head2 fire_hooks

  $depgraph->fire_hooks('new_distribution_indexed', $payload);

Call all the coderefs registered for this hook with C<attach_hook>.

=head2 full_dependency_graph

  $depgraph->full_dependency_graph(filter_with_regex => qr/.../);

Builds the full dependency graph for the whole package index.  This
works by looping over all module names in the index, skipping the ones
that don't match the regex passed in the optional
C<filter_with_regex>, and calling C<module_dependency_graph> on them.

Returns self.

=head2 grow_graph

  my $graph = $depgraph->grow_graph;

Returns a brand new directed L<Graph> instance, with vertices and
edges as described previously.

=head2 module_dependency_graph

  $depgraph->module_dependency_graph('Acme::Weborama',
      filter_with_regex => qr/.../);

Builds the dependency graph for the module provided.

C<filter_with_regex>, if provided, should be a regex that matches the
modules you're interested in, e.g. C<qr/^Acme::>.  It will be used
every time a distribution tarball is unpacked, looking for
dependencies; any dependency that doesn't match the regex will not be
investigated or added to the graph.

Since C<module_dependency_graph> properly keeps all its interesting
state in the L<Weborama::CPANTools::DependencyGraph> object, it can be
called multiple times to build a graph incrementally.

Returns self.

=head2 parse_meta_json

  my $metadata = $depgraph->parse_meta_json('path/to/META.json');

Slurp, parse and return the metadata in the file provided.  The return
value is a plain Perl reference, not an object.  If the parsing
failed, returns false (to fall through to other methods of obtaining
the metadata).

=head2 parse_meta_yaml

Like C<parse_meta_json>, for F<META.yml>.

=head2 reindex

  $depgraph->reindex;

Fetches a brand new copy of F<modules/02packages.details.txt.gz>,
rebuilds C<package_index> and invalidates parts of C<dist_metadata>,
C<modules_visited> and C<tarballs_visited> accordingly.

After a call to C<reindex>, the instance is ready to rebuild the
missing parts of the dependency graph with C<full_dependency_graph> or
C<module_dependency_graph>.

Returns self.

=head2 run_configure_script

  my $metadata = $depgraph->run_configure_script('path/to/Build.PL');

Runs the configure script provided (e.g. F<Build.PL> or
F<Makefile.PL>), in the hopes of generating a F<MYMETA.json> or
F<MYMETA.yaml> usable to determine distribution metadata.  If
successful (the configure scripts exits successfully), attempts to
parse the C<MYMETA> file with C<parse_meta_json> or
C<parse_meta_yaml>, and returns the result.

This method used to be called whenever a distribution had
C<dynamic_config> set to a true value in the metadata returned by the
parsing methods, but this turned out to be very often indeed.  It
appears older metadata formats did not include this key, and
L<CPAN::Meta> assumes it is true when absent.  It is currently called
only when no C<META> file has been found in the tarball.

=head2 serialize

  $depgraph->serialize('path/to/file');

Serialize the instance and write it to file.  Currently this is done
via L<Storable>'s C<nstore>.

=head1 HOOKS

Hooks are called in the order they were attached.

=head2 dist_changed

This hook is fired during the preliminary reindexing phase (if it
occurs at all), for each distribution whose modules changed in the
package index.

The payload is

  { dist_changed => 'Foo-Bar' }

=head2 missing_dependency

This hook is fired whenever a module is being considered (because it
has been found as a prereq of a distribution), but the module is not
in C<package_index>.

The payload is

  { module => 'Foo::Bar' }

=head2 module_changed

This hook is fired during the preliminary reindexing phase (if it
occurs at all), for each module changed in the index: new modules,
modules moved from a distribution to another (including version
changes), and modules removed from the index.

The payload is

  { module => 'Foo::Bar',
    old_module => 'old/package/index/entry',
    new_module => 'new/package/index/entry' }

New modules will not have an C<old_module> entry and removed modules
will not have a C<new_module> entry.

=head2 new_distribution_indexed

This hook is fired whenever a module is being considered, once per
distribution.

The payload is

  { distribution => 'Foo-Bar',
    tarball      => 'F/FO/FOO/Foo-Bar-0.018.tar.gz',
    extracted_at => '/tmp/...',
    version      => version->parse('0.018'),
    metadata     => CPAN::Meta->new(...),
    prereqs      => metadata->effective_prereqs }

where C<extracted_at> is the path to a sandbox that is still available
for further study (POD generation, etc.) but will be removed
immediately after, C<version> is a L<version> object with the value
extracted from the metadata, and C<prereqs> is the result of calling
C<effective_prereqs> from the metadata object.

=head2 new_module_indexed

This hook is fired whenever a module is being considered, after
C<new_distribution_indexed> was fired if appropriate.  Unlike
C<new_distribution_indexed>, it is called for every module that is not
a missing dependency.

The payload is

  { distribution => 'Foo-Bar',
    module       => 'Foo::Bar' }

=head2 perl_indexed

This hook is fired when the Perl tarball is found in the package
index, when C<perl_tarball> is set by its builder.

The payload is

  { distribution => 'perl', # always
    tarball      => 'J/JE/JESSE/perl-5.12.2.tar.bz2',
    version      => $self->perl_version }

=head1 SEE ALSO

L<CPAN::Meta::Prereqs>, L<CPAN::Meta::Spec>, L<Graph>

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
