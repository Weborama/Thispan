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
use File::Temp;
use Graph;
use HTTP::Tiny;
use IO::File;
use JSON;
use List::MoreUtils qw/uniq/;
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
                 isa => sub { blessed($_[0]) and $_[0]->isa('URI') },
                 default => sub { URI->new(q{http://www.cpan.org/}) },
                 coerce => sub {
                     unless (blessed($_[0])) {
                         return URI->new($_[0])
                     }
                 });
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

sub attach_hook {
    my ($self, $hook_name, $callback) = @_;
    push @{$self->hook_map->{$hook_name}}, $callback;
    return $self;
}

sub fire_hooks {
    my ($self, $hook_name, @args) = @_;
    foreach my $callback (@{$self->hook_map->{$hook_name}}) {
        $callback->($self, $hook_name, @args);
    }
    return $self;
}

sub serialize {
    my ($self, $filename) = @_;
    $self->_set_hook_map({});
    nstore($self, $filename);
    return $filename;
}

sub fetch_file {
    my $url = shift;
    my $destination = shift;
    print "Fetching file at $url... ";
    if ($url->scheme eq 'http') {
        my $response = HTTP::Tiny->new->get($url);
        say 'Done.';
        croak(sprintf(q{Could not fetch file at %s: %d %s},
                      $url, $response->{status}, $response->{reason}))
            unless $response->{success};
        my $content = $response->{content};
        my $fh;
        if ($destination) {
            $fh = IO::File->new($destination, 'w');
        } else {
            ($fh, $destination) = File::Temp::tempfile(UNLINK => 0);
        }
        $fh->print($content);
        $fh->close;
    } elsif ($url->scheme eq 'file') {
        (undef, $destination) = File::Temp::tempfile(UNLINK => 0)
            unless $destination;
        copy($url->file, $destination) or die(sprintf("can't fetch file at %s: %s",
                                                      $url->file, $!));
        say 'Done.';
    } else {
        croak(sprintf(q{Not sure how to handle URI scheme '%s'},
                      $url->scheme));
    }
    return $destination;
}

sub parse_meta_json {
    my ($metafile) = @_;
    my $meta_contents = try {
        JSON::decode_json(scalar $metafile->slurp);
    } catch {
        warn "While trying to parse $metafile: $_";
        return;
    };
    return unless $meta_contents;
    # if ($meta_contents->{dynamic_config}) {
    #     warn "$metafile has dynamic_config set to a true value.\n";
    #     warn "Prereqs must be determined by running a build script.\n";
    #     return;
    # }
    return $meta_contents;
}

sub parse_meta_yaml {
    my ($metafile) = @_;
    my $meta_contents = try {
        YAML::Load(scalar $metafile->slurp);
    } catch {
        warn "While trying to parse $metafile: $_";
        return;
    };
    return unless $meta_contents;
    # if ($meta_contents->{dynamic_config}) {
    #     warn "$metafile has dynamic_config set to a true value.\n";
    #     warn "Prereqs must be determined by running a build script.\n";
    #     return;
    # }
    return $meta_contents;
}

sub run_configure_script {
    my ($sandbox, $make_or_build_pl) = @_;
    my (undef, $tempfile) = File::Temp::tempfile(UNLINK => 0);
    try {
        system("cd '$sandbox' && perl '$make_or_build_pl' > $tempfile 2>&1");
        unlink $tempfile;
        return 1;
    } catch {
        warn "While trying to run '$make_or_build_pl': $_\n";
        warn "Logs can be found at '$tempfile'.\n";
        return;
    } or return;
    return parse_meta_json($sandbox->file('MYMETA.json'))
        || parse_meta_yaml($sandbox->file('MYMETA.yml'));
}

sub find_perl_tarball {

    my $self = shift;

    foreach my $tarball (values %{$self->package_index}) {
        next unless $tarball =~ m{/perl-(5[\d.]+).tar.(gz|bz2)};
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
    my $package_index_filename = fetch_file(URI->new_abs('modules/02packages.details.txt.gz', $self->mirror));

    my $index_contents;

    my $index_archive = Archive::Extract->new(archive => $package_index_filename,
                                              type => 'gz');
    my (undef, $extracted_filename) = File::Temp::tempfile(UNLINK => 0);
    say "Extracting $extracted_filename...";
    $index_archive->extract(to => $extracted_filename);
    unlink $package_index_filename;
    my $fh = IO::File->new($extracted_filename, 'r');

    my %index;

    # parse and transform 02packages.details.txt
    my $in_header = 1;
    say "Parsing $extracted_filename...";
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

    my $sandbox = Path::Class::tempdir(CLEANUP => 0);

    # the tarball needs a filename with a proper extension otherwise
    # Archive::Extract gets confused
    my $tarball = fetch_file($uri, $sandbox->file($filename));

    my $dist_archive = Archive::Extract->new(archive => $tarball);
    say "Extracting $tarball...";
    $dist_archive->extract(to => $sandbox);
    unlink $tarball;

    # done with the dist tarball, now we have an extracted directory
    # in $sandbox

    my @files_in_sandbox = $sandbox->children(no_hidden => 1);

    if (@files_in_sandbox == 1
        and $files_in_sandbox[0]->is_dir) {
        # properly extracted tarball.  pretend that's what we meant
        # all along.  if we don't go through here it means it was one
        # of these tarballs where everything is just at the root
        $sandbox = $files_in_sandbox[0];
    }

    say "Looking for META files in all the wrong places...";

    # deafening applause
    my $meta_contents =
           -e $sandbox->file('META.json')   && parse_meta_json($sandbox->file('META.json'))
        || -e $sandbox->file('META.yml')    && parse_meta_yaml($sandbox->file('META.yml'))
        || -e $sandbox->file('Build.PL')    && run_configure_script($sandbox, $sandbox->file('Build.PL'))
        || -e $sandbox->file('Makefile.PL') && run_configure_script($sandbox, $sandbox->file('Makefile.PL'));

    unless ($meta_contents) {
        die('Impossible to determine prereqs!');
    }

    my $metadata = CPAN::Meta->new($meta_contents, { lazy_validation => 1 });

    return [ $sandbox, $metadata ];

}

sub full_dependency_graph {

    my $self = shift;
    my %args = validate(@_,
                        { filter_with_regex => { default => undef } });

    say "Perl tarball appears to be at ".$self->perl_tarball;

    foreach my $module (keys %{$self->package_index}) {

        next if exists $self->modules_visited->{$module};
        next unless (not $args{filter_with_regex}
                     or $module =~ $args{filter_with_regex});
        say "Now checking dependency chain for '$module'...";
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
            if (version->parse(Module::CoreList->first_release($this_module))
                <= version->parse($self->perl_version)) {
                # it's in core.  proceed, citizen
                say "        $this_module is a core module (unindexed), skipping";
                $self->modules_visited->{$this_module} = 'perl';
                $tarball_path = $self->perl_tarball;
            } else {
                # missing dependency ermahgerd!
                $self->modules_visited->{$this_module} = undef;
                $self->fire_hooks('missing_dependency', { module => $this_module });
                next MODULE;
            }

        } elsif ($tarball_path eq $self->perl_tarball) {

            say "        $this_module is a core module, skipping";
            $self->modules_visited->{$this_module} = 'perl';

        } elsif (not $self->tarballs_visited->{$tarball_path}) {

            # if not already done, create the vertex in the dependency
            # graph.  we track advancement by tarball instead of dist
            # because this way we save having to unpack the tarball to
            # check what dist it provides
            my ($sandbox_path, $metadata) = @{$self->fetch_and_get_metadata($this_module)};

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
                    # interesting to us, add it to the list of modules
                    # we still need to process
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
            $sandbox_path->rmtree;

            # map tarballs to the distribution contained, and mark
            # them as already analyzed
            $self->tarballs_visited->{$tarball_path} = $metadata->name;

        }

        # add current module to list of modules provided by its distribution
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

        }

    }

    foreach my $old_module (keys %{$self->package_index}) {

        # modules that are in the current package index but not the
        # new one are removed
        $modules_changed{$old_module}++
            unless exists $new_package_index->{$old_module};

    }

    # three indexes/caches must be partially invalidated:
    # dist_metadata (map of dist names to metadata), tarballs_visited
    # (map of tarball paths to dist names), and modules_visited (map
    # of module names to parent dist names)

    my @dists_changed = grep { defined $_ } map { $self->modules_visited->{$_} } keys %modules_changed;
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
computations done so far.  However, if the mirror state changes
(e.g. a new version of a distribution is uploaded), there is no
mechanism so far to invalidate or rebuild only part of the graph, and
you're better off trashing your object and building a new one.

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

=head2 graph

(read-only directed Graph object)

The full graph dependency, as far as we have been able to build it
(e.g. after a call to C<module_dependency_graph> or
C<full_dependency_graph>).  You can call the usual Graph methods on
it, so for instance to get the list of distributions that have no
dependencies (likely to be "perl" and possibly some distributions that
don't declare core modules as dependencies):

  my @sinks = $depgraph->graph->sink_vertices;

Or distributions that have no reverse dependencies:

  my @sources = $depgraph->graph->source_vertices;

=head2 mirror

(read-only URI object, optionally coerced from a string)

The URL to the mirror providing the tarballs.  Defaults to
"http://www.cpan.org/".

=head2 perl_tarball

(read-only lazy string)

The path to the Perl tarball, found in the index.  This attribute's
builder also sets C<perl_version>, so if you provide it manually, make
sure to also provide C<perl_version>.

=head2 perl_version

(read-only string, mutator at C<_set_perl_version>)

Version number extracted from the Perl tarball path in the index.
This is set by the builder method for C<perl_tarball>.

=head1 METHODS

=head2 full_dependency_graph

  my $graph = $depgraph->full_dependency_graph(requirement_phases => [qw/.../],
                                               requirement_types => [qw/.../],
                                               filter_with_regex => qr/.../);

Builds the full dependency graph for the whole package index.  This
works by looping over all module names in the index, skipping the ones
that don't match the regex passed in C<filter_with_regex>, and calling
C<module_dependency_graph> on them, currying all other arguments.

Returns said graph.

=head2 module_dependency_graph

  my $graph = $depgraph->module_dependency_graph('Acme::Weborama',
      requirement_phases => [qw/.../],
      requirement_types => [qw/.../],
      filter_with_regex => qr/.../);

Builds the dependency graph for the module provided.  All arguments
except the module name are optional.

C<requirement_phases> is passed on to the L<CPAN::Meta::Prereqs>
object, to allow filtering on specific prereqs phases.  The prereqs
phases are all defined in L<CPAN::Meta::Spec>.  Valid phases include
C<configure>, C<runtime>, C<build>, C<test> and C<develop>; by
default, we enable all but C<develop>.

C<requirement_types> is similar, but allows filtering on the nature of
the relationship.  Prereq types are also defined in
L<CPAN::Meta::Spec>.  Valid types include C<requires>, C<recommends>,
C<suggests> and C<conflicts>; by default, we enable only C<requires>.

C<filter_with_regex> should be a regex that matches the modules you're
interested in, e.g. C<qr/^Acme::>.  It will be used every time a
distribution tarball is unpacked, looking for dependencies; any
dependency that doesn't match the regex will not be investigated or
added to the graph.

Since C<module_dependency_graph> properly keeps all its interesting
state in the L<Weborama::CPANTools::DependencyGraph> object, it can be
called multiple times to build a graph incrementally.

Returns the whole dependency graph built so far.  This may not be what
you want if you're interested in the dependency chain of a single
module, but you have already built some other modules' chains.  In
that case, consider using the L<Graph> methods to refine the result,
e.g.

  $depgraph->module_dependency_graph('Acme::Foo');
  my $graph = $depgraph->module_dependency_graph('Acme::Bar');
  # now $graph has Acme::Foo, Acme::Bar, and all of their dependencies
  # these are the interesting dists as far as Foo is concerned:
  my @dists = $graph->all_successors('Acme::Bar');

=head1 SEE ALSO

L<CPAN::Meta::Prereqs>, L<CPAN::Meta::Spec>, L<Graph>

=head1 AUTHOR

Fabrice Gabolde <fgabolde@weborama.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Weborama.  No license is granted to other entities.

=cut
