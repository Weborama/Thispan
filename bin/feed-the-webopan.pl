#!/usr/bin/perl

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use Log::Any::Adapter ('Stdout');
use Path::Class;
use ThisPAN::Schema;
use ThisPAN::Indexing;
use Getopt::Long::Descriptive;
use YAML;

my ($opt, $usage) = describe_options(
    'feed-the-webopan.pl %o',
    [ 'mirror=s', 'CPAN mirror root' ],
    [ 'workdir=s', 'ThisPAN work directory' ],
    [ 'base-url=s', 'ThisPAN base URL for POD links' ],
    [ 'state=s', 'Save/load graph data from this save file' ],
    [ 'dsn=s', 'DSN for database connections' ],
    [ 'config=s', 'Provide defaults for all previous values from a YAML config file' ]);

my $config = $opt->config ? YAML::LoadFile($opt->config) : {};

my %options = (
    mirror     => $opt->mirror   // $config->{mirror},
    workdir    => $opt->workdir  // $config->{workdir},
    'base-url' => $opt->base_url // $config->{'base-url'},
    state      => $opt->state    // $config->{state},
    dsn        => $opt->dsn      // $config->{dsn},
    );

my @missing_options = grep { not defined $options{$_} } qw/workdir base-url dsn/;
croak(sprintf(q{Missing values for mandatory options: %s},
              join(', ', @missing_options)))
    if @missing_options;

my $schema = ThisPAN::Schema->connect($options{dsn});

my $indexer = ThisPAN::Indexing->new(
    (mirror => $options{mirror}) x!! $options{mirror},
    base_url => $options{'base-url'},
    workdir => $options{workdir},
    (graph_factory_save_file => $options{state}) x!! $options{state},
    schema => $schema);

my $graph = $indexer->run;

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

my $fh = file($options{workdir}, 'depgraph.json')->openw;
$fh->print(JSON::encode_json(\@json));
$fh->close;

exit 0;
