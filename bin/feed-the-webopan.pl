#!/usr/bin/perl

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use Path::Class;
use File::Copy;
use JSON;
use Storable qw/nstore retrieve/;
use URI;
use ThisPAN::Schema;
use ThisPAN::DependencyGraph;
use Pod::Simple::XHTML;

{ no warnings 'redefine';
  # force detection of code as Perl -- most interesting verbatim
  # blocks are SYNOPSIS and method usage examples
  sub Pod::Simple::XHTML::start_Verbatim {
      $_[0]{'scratch'} = '<pre><code class="language-perl">';
  }
}

use Getopt::Long::Descriptive;

my ($opt, $usage) = describe_options(
    'feed-the-webopan.pl %o',
    [ 'mirror=s', 'CPAN mirror root' ],
    [ 'workdir=s', 'ThisPAN work directory',
      { required => 1 } ],
    [ 'base-url=s', 'ThisPAN base URL for POD links',
      { required => 1 } ],
    [ 'reindex', 'Check for changes if resuming from a previous run' ],
    [ 'resume=s', 'Save/load graph data from this save file' ],
    [ 'regex=s', 'Filter with this regex' ]);

my $regex = $opt->regex;

my $graphmaker;

if ($opt->resume and -e $opt->resume) {
    # a save file is provided, and it exists
    unless ($graphmaker = retrieve($opt->resume)) {
        # other errors are proper exceptions thrown by Storable
        die "Could not restore graph factory from storage: unspecified I/O error";
    }
    if ($graphmaker->mirror ne URI->new($opt->mirror)) {
        die "Can't restore graph factory from save file with different mirror!";
    }
    if ($opt->reindex) {
        $graphmaker->reindex;
    }
} else {
    # save file not provided, or not saved to (TODO: differentiate
    # thoses cases in the log output)
    $graphmaker = ThisPAN::DependencyGraph->new(
        (mirror => $opt->mirror) x !!($opt->mirror));
}

my $schema = ThisPAN::Schema->connect('dbi:SQLite:foo.db');

my @postprocess;

sub insert_perl_distribution {

    my ($graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, tarball, version

    my $distribution = $payload->{distribution};

    my $dist_object = $schema->resultset('Distribution')->create(
        { name => $distribution,
          version => $payload->{version},
          changes_path => undef,
          dependency_json_path => undef,
          metadata_json_blob => {},
          tarball_path => URI->new_abs('authors/id/' . $payload->{tarball}, $opt->mirror) });

}

sub insert_new_distribution {

    my ($graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, tarball, extracted_at, version, metadata, prereqs

    my $distribution = $payload->{distribution};
    dir($opt->workdir, $distribution)->mkpath;

    # copy extracted_at/(Changes|CHANGES)
    my $changes_path;
    if (-e $payload->{extracted_at}->file('Changes')) {
        copy($payload->{extracted_at}->file('Changes'),
             file($opt->workdir, $distribution, 'Changes'));
        $changes_path = file($distribution, 'Changes');
    } elsif (-e $payload->{extracted_at}->file('CHANGES')) {
        copy($payload->{extracted_at}->file('CHANGES'),
             file($opt->workdir, $distribution, 'Changes'));
        $changes_path = file($distribution, 'Changes');
    }

    # make path to depgraph.json, will fill it in later from full
    # graph
    my $dependency_json_path = file($opt->workdir, $distribution, 'depgraph.json');

    # find module files and render PODs
    my @modules = File::Find::Rule->file->name('*.pm')->in(dir($payload->{extracted_at}, 'lib'));

    foreach my $module (@modules) {
        my $pod_renderer = Pod::Simple::XHTML->new;
        $pod_renderer->html_header('');
        $pod_renderer->html_footer('');
        $pod_renderer->perldoc_url_prefix($opt->base_url . 'module/');
        $pod_renderer->output_string(\my $html);
        $pod_renderer->parse_file($module);
        $module =~ s/\.pm$/.html/;
        $module = file($module)->relative(dir($payload->{extracted_at}, 'lib'));
        my $rendered_pod_path = file($opt->workdir, $distribution, 'pod', $module);
        $rendered_pod_path->parent->mkpath;
        my $fh = $rendered_pod_path->openw;
        $fh->print($html);
        $fh->close;
    }

    my $dist_object = $schema->resultset('Distribution')->create(
        { name => $distribution,
          version => $payload->{version},
          changes_path => $changes_path ? $changes_path->stringify : undef,
          dependency_json_path => $dependency_json_path ? $dependency_json_path->stringify : undef,
          metadata_json_blob => $payload->{metadata},
          tarball_path => URI->new_abs('authors/id/' . $payload->{tarball}, $opt->mirror) });

    push @postprocess, {
        distribution => $distribution,
        json_at => $dependency_json_path,
        object => $dist_object,
        prereqs => $payload->{prereqs},
    };

}

sub insert_new_module {
    
    my ($graphmaker, $hook_name, $payload) = @_;
    # payload has keys: distribution, module

    my $filename = $payload->{module} . '.html';
    my $rendered_pod_path = file($payload->{distribution}, 'pod', split('::', $filename));

    my $distribution = $schema->resultset('Distribution')->find({ name => $payload->{distribution} });
    unless ($distribution) {
        warn(sprintf(q{Trying to create module %s for missing distribution %s},
                     $payload->{module},
                     $payload->{distribution}));
        return;
    }
    eval {
        $distribution->create_related('modules',
                                      { name => $payload->{module},
                                        rendered_pod_path => -e file($opt->workdir, $rendered_pod_path) ? $rendered_pod_path->stringify : undef });
    };
    if (my $error = $@) {
        warn(sprintf(q{While trying to insert module %s for dist %s: %s},
                     $payload->{module},
                     $payload->{distribution},
                     $error));
    }

}

# $graphmaker->attach_hook('missing_dependency', sub { my ($self, $hook_name, $payload) = @_;
#                                                      print Dumper({ hook => $hook_name,
#                                                                     payload => $payload }) });
$graphmaker->attach_hook('perl_indexed', \&insert_perl_distribution);
$graphmaker->attach_hook('new_distribution_indexed', \&insert_new_distribution);
$graphmaker->attach_hook('new_module_indexed', \&insert_new_module);

$graphmaker->full_dependency_graph(
    (filter_with_regex => $regex) x !!$regex);

if ($opt->resume) {
    $graphmaker->serialize($opt->resume);
}

my $graph = $graphmaker->grow_graph;

# have to rebuild a single big graph every single time.  if we built
# many small graphs instead, finding which ones to update every time
# would actually be more expensive :/
my @json;
foreach my $vertex ($graph->vertices) {
    push @json, {
        name => $vertex,
        size => 1,
        imports => [ $graph->successors($vertex) ],
        ancestors => { map { $_ => 1 } $graph->all_predecessors($vertex) },
        descendants => { map { $_ => 1 } $graph->all_successors($vertex) } };
}

my $fh = file($opt->workdir, 'depgraph.json')->openw;
$fh->print(JSON::encode_json(\@json));
$fh->close;

foreach my $postprocess_job (@postprocess) {

    my $distribution = $postprocess_job->{distribution};

    # link the dists together

    foreach my $prereq_phase (@{$graphmaker->requirement_phases}) {
        foreach my $prereq_type (@{$graphmaker->requirement_types}) {
            my $prereqs = $postprocess_job->{prereqs}->requirements_for($prereq_phase, $prereq_type)->as_string_hash;
            foreach my $dependency (keys %{$prereqs}) {
                my $dist_of_dependency = $graphmaker->modules_visited->{$dependency};
                next unless $dist_of_dependency;
                my $dep_object = $schema->resultset('Distribution')->find({ name => $dist_of_dependency });
                unless ($dep_object) {
                    warn("Can't find dist dependency $dist_of_dependency for $distribution!");
                    next;
                }
                my $module_object = $schema->resultset('Module')->find({ name => $dependency });
                unless ($module_object) {
                    warn("Can't find module dependency $dependency for $distribution!");
                    next;
                }
                say(sprintf(q{Now linking %s to %s through %s},
                            $distribution, $dist_of_dependency, $dependency));
                $schema->resultset('Relationship')->create(
                    { parent => $postprocess_job->{object}->id,
                      child => $dep_object->id,
                      module => $module_object->id,
                      phase => $prereq_phase,
                      type => $prereq_type,
                      version => $prereqs->{$dependency} });
            }
        }
    }

}

exit 0;
