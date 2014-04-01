#!/usr/bin/perl

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use Path::Class;
use ThisPAN::Schema;
use ThisPAN::Indexing;
use Getopt::Long::Descriptive;

my ($opt, $usage) = describe_options(
    'feed-the-webopan.pl %o',
    [ 'mirror=s', 'CPAN mirror root' ],
    [ 'workdir=s', 'ThisPAN work directory',
      { required => 1 } ],
    [ 'base-url=s', 'ThisPAN base URL for POD links',
      { required => 1 } ],
    [ 'resume=s', 'Save/load graph data from this save file' ],
    [ 'dsn=s', 'DSN for database connections' ]);

my $schema = ThisPAN::Schema->connect($opt->dsn);

my $indexer = ThisPAN::Indexing->new(
    (mirror => $opt->mirror) x!! $opt->mirror,
    base_url => $opt->base_url,
    workdir => $opt->workdir,
    (graph_factory_save_file => $opt->resume) x!! $opt->resume,
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

my $fh = file($opt->workdir, 'depgraph.json')->openw;
$fh->print(JSON::encode_json(\@json));
$fh->close;

exit 0;
