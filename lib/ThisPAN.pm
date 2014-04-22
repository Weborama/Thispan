package ThisPAN;

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use List::Util qw/first/;
use List::MoreUtils qw/uniq/;
use Path::Class;
use Dancer ':syntax';
use Dancer::Plugin::DBIC;

our $VERSION = '0.002';

sub mirror_exists_or_404 {
    my $mirror_name = param('mirror');
    unless (exists setting('mirrors')->{$mirror_name}) {
        forward '/no_such_mirror', { mirror => $mirror_name };
    }
}

sub mirror_uri_for {
    my ($uri, @rest) = @_;
    $uri =~ s{^/?}{};
    if (param('mirror')) {
        $uri = sprintf('/mirror/%s/%s',
                       param('mirror'),
                       $uri);
    }
    $uri =~ s{/?$}{};
    return uri_for($uri,
                   @rest);
}

sub mirror_schema {
    return schema(param('mirror'));
}

sub workdir_of_mirror {
    return setting('mirrors')->{param('mirror')}->{workdir};
}

hook 'before_template_render' => sub {
    my $tokens = shift;
    $tokens->{mirror_uri_for} = \&mirror_uri_for;

    # switch between mirrors
    my $current_path = request->path_info;
    $current_path = '' if $current_path eq '/';

    foreach my $mirror (keys %{setting('mirrors')}) {
        my $current_path_in_other_mirror = $current_path;
        $current_path_in_other_mirror =~ s{(?:/mirror/[^/]+?)?(/|$)}{/mirror/$mirror$1};
        push @{$tokens->{mirror_list}}, {
            name => $mirror,
            title => setting('mirrors')->{$mirror}->{title},
            url => uri_for($current_path_in_other_mirror, scalar(params('query'))),
        };
    }

    $tokens->{selected_mirror} = param('mirror') // 'nomirror';
    $tokens->{thispan_version} = $VERSION;

};

get '/no_such_mirror' => sub {
    status 404;
    template 'no-such-mirror', {
        mirror => param('mirror'),
    };
};

get '/no_such_distribution' => sub {
    status 404;
    template 'no-such-dist', {
        distribution => param('distribution'),
    };
};

get '/no_such_module' => sub {
    status 404;
    template 'no-such-mod', {
        module => param('module'),
    };
};

get '/' => sub {
    template 'mirror-list';
};

get '/mirror/:mirror' => sub {
    # module search by name
    mirror_exists_or_404();
    template 'index';
};

get '/mirror/:mirror/module-search/json' => sub {

    my $query = param('q');
    my @results = mirror_schema->resultset('Module')->search({ name => { like => '%'.$query.'%' } },
                                                             { rows => 10,
                                                               order_by => 'name' })->all;
    return to_json([ map { { label => $_->name,
                             url => mirror_uri_for("/module/".$_->name)->as_string } } @results ]);

};

get '/mirror/:mirror/module-search' => sub {

    mirror_exists_or_404();

    my $query = param('q');
    my $page = param('p');
    my $rs = mirror_schema->resultset('Module')->search({ name => { like => '%'.$query.'%' } },
                                                        { rows => 20,
                                                          page => $page || 1,
                                                          order_by => 'name' });
    template 'module-list', {
        query => $query,
        pager => $rs->pager,
        result_total_count => $rs->pager->total_entries,
        result_displayed_count => $rs->count,
        results => [ $rs->all ],
    };

};

get '/mirror/:mirror/module/:module' => sub {

    mirror_exists_or_404();

    my $module_name = param('module');

    my $module = mirror_schema->resultset('Module')->find({ name => $module_name },
                                                          { key => 'name_unique' });

    unless ($module) {
        forward '/no_such_module', {
            module => $module_name
        };
    }

    my $pod;
    if ($module->rendered_pod_path) {
        my $pod_file = file(workdir_of_mirror(), $module->rendered_pod_path);
        if (-e $pod_file) {
            $pod = $pod_file->slurp;
        }
    }

    my $parent_distribution = $module->distribution;

    template 'module', {
        module => $module->name,
        pod => $pod,
        parent_distribution => $parent_distribution->name,
    }; 

};

get '/mirror/:mirror/distribution/:distribution' => sub {

    mirror_exists_or_404();

    my $distribution_name = param('distribution');

    my $distribution = mirror_schema->resultset('Distribution')->find({ name => $distribution_name },
                                                                      { key => 'name_unique' });

    unless ($distribution) {
        forward '/no_such_distribution', {
            distribution => $distribution_name
        };
    }

    my $changes;
    if ($distribution->changes_path) {
        my $changes_file = file(workdir_of_mirror(), $distribution->changes_path);
        $changes = -e $changes_file ? $changes_file->slurp : undef;
    }

    my $metadata = $distribution->metadata_json_blob;

    # blah blah prefetch prereq labels and distributions (names at least)
    my @modules_contained = map { $_->name } $distribution->search_related('modules')->all;

    my @all_prereqs = $distribution->relationship_parents;
    my @reverse_prereqs = $distribution->relationship_children;

    my $prereqs;

    foreach my $prereq (@all_prereqs) {
        $prereqs->{$prereq->phase}->{$prereq->type}->{$prereq->child->name} = $prereq->version;
    }

    my @reverse_dependency_list = uniq map { $_->parent->name } @reverse_prereqs;

    template 'distribution', {
        distribution => $distribution->name,
        version => $distribution->version,
        changes => $changes,
        metadata => $metadata,
        modules_contained => \@modules_contained,
        prereqs => $prereqs,
        rdepends => \@reverse_dependency_list,
    };

};

get '/mirror/:mirror/distribution/:distribution/depgraph.json' => sub {

    mirror_exists_or_404();

    my $distribution_name = param('distribution');
    my $only = param('only') // 'both';
    my $depth_successors = param('ds') // undef;
    my $depth_predecessors = param('dp') // undef;
    my $filter_name = param('filter') // 'none';
    my $filters = setting('graph_filters');
    my $filter_pair = first { $filter_name eq $_->{name} } @{$filters->{filters}};

    # beeg file, might take some time!
    my $full_depgraph = from_json(scalar(file(workdir_of_mirror(), 'depgraph.json')->slurp));
    my $depgraph;

    foreach my $vertex (@{$full_depgraph}) {
        if ($filter_pair) {
            next if $vertex->{name} !~ $filter_pair->{regex};
        }
        if ($only eq 'descendants') {
            # descendants are those who have us in their ancestry
            # lineage
            if (exists $vertex->{ancestors}->{$distribution_name}
                or $vertex->{name} eq $distribution_name) {
                # don't need those for d3.js, save some bandwidth
                delete $vertex->{ancestors};
                delete $vertex->{descendants};
                $depgraph->{$vertex->{name}} = $vertex;
            }
        } elsif ($only eq 'ancestors') {
            # ancestors are those who have us in their descendants
            # lineage
            if (exists $vertex->{descendants}->{$distribution_name}
                or $vertex->{name} eq $distribution_name) {
                # don't need those for d3.js, save some bandwidth
                delete $vertex->{ancestors};
                delete $vertex->{descendants};
                $depgraph->{$vertex->{name}} = $vertex;
            }
        } else {
            if (exists $vertex->{ancestors}->{$distribution_name}
                or exists $vertex->{descendants}->{$distribution_name}
                or $vertex->{name} eq $distribution_name) {
                # don't need those for d3.js, save some bandwidth
                delete $vertex->{ancestors};
                delete $vertex->{descendants};
                $depgraph->{$vertex->{name}} = $vertex;
            }
        }
    }

    foreach my $vertex (keys %{$depgraph}) {
        # now remove all children that are not in our subgraph
        $depgraph->{$vertex}->{imports} = [ grep { exists $depgraph->{$_} } @{$depgraph->{$vertex}->{imports}} ];
        # and generate URIs
        $depgraph->{$vertex}->{url} = mirror_uri_for('/distribution/' . $vertex . '/depgraph',
                                                     { filter => $filter_name })->as_string;
    }

    content_type 'application/json';
    return to_json([ values %{$depgraph} ]);
};

get '/mirror/:mirror/distribution/:distribution/depgraph' => sub {

    my $distribution_name = param('distribution');

    my $distribution = mirror_schema->resultset('Distribution')->find({ name => $distribution_name },
                                                                      { key => 'name_unique' });

    unless ($distribution) {
        forward '/no_such_distribution', {
            distribution => $distribution_name
        };
    }

    my @available_filters = sort { $a->{name} cmp $b->{name} } @{setting('graph_filters')->{filters}};
    unshift @available_filters, { name => 'none',
                                  regex => '.*' };
    my $active_filter = param('filter');

    if (not(defined($active_filter))
        and setting('graph_filters')->{filtering_config} eq 'smart') {

        # no specific filter provided.  if filtering_config is set and
        # "smart", try to infer a good filter from what the main dist
        # already matches
        FILTER_PAIR:
        foreach my $filter_pair (@{setting('graph_filters')->{filters}}) {
            if ($distribution_name =~ $filter_pair->{regex}) {
                $active_filter = $filter_pair->{name};
                last FILTER_PAIR;
            }
        }

    }

    # still not defined?
    $active_filter //= 'none';

    my @all_prereqs = $distribution->relationship_parents;
    my @reverse_prereqs = $distribution->relationship_children;

    my $prereqs;

    foreach my $prereq (@all_prereqs) {
        $prereqs->{$prereq->phase}->{$prereq->type}->{$prereq->child->name} = $prereq->version;
    }

    my @reverse_dependency_list = uniq map { $_->parent->name } @reverse_prereqs;

    template 'depgraph', {
        active_filter => $active_filter // 'none',
        available_filter_pairs => \@available_filters,
        distribution => $distribution_name,
        prereqs => $prereqs,
        rdepends => \@reverse_dependency_list,
        depgraph_json_url => mirror_uri_for('/distribution/' . $distribution_name . '/depgraph.json',
                                            { filter => $active_filter,
                                              only => param('only') // 'both' })->as_string,
    };

};

get '/mirror/:mirror/distribution/:distribution/download' => sub {

    mirror_exists_or_404();

    my $distribution_name = param('distribution');

    my $distribution = mirror_schema->resultset('Distribution')->find({ name => $distribution_name },
                                                                      { key => 'name_unique' });

    unless ($distribution) {
        forward '/no_such_distribution', {
            distribution => $distribution_name
        };
    }

    my $path_to_tarball = URI->new($distribution->tarball_path);
    if ($path_to_tarball->scheme eq 'file') {
        send_file($path_to_tarball->file,
                  filename => file($path_to_tarball->file)->basename,
                  system_path => 1);
    } else {
        redirect $path_to_tarball;
    }

};

true;
