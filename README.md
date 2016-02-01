# ThisPAN

ThisPAN is a lightweight CPAN mirror browser.

See it in action
[here](http://www.insecable.net/thispan-demo/mirror/local/distribution/ThisPAN)!

## Features

+ Reverse dependencies (*if* they are specified in `META.yml` or
  `META.json`)
+ Interactive dependency (and reverse dependency) graph ala Stratopan,
  with d3.js (again only for prereqs in the metadata files)
+ Pretty POD render with syntax highlighting thanks to highlight.js
+ Index and browse multiple mirrors
+ PSGI-compliant
+ Reasonably lightweight: Dancer + DBIC
+ Free and open source software

## Not features

+ Indexing of past releases.  ThisPAN is intended to provide an up to
  date view of what's in your repository *right now*.  Internal
  mirrors for darkpans don't usually keep old releases.
+ PAUSE-like uploading.  ThisPAN does not manage uploading at all.
  Use your existing tools, e.g. Pinto or mcpani.
+ Any understanding of what's a version number good for, including
  whether a given distribution satisfies a dependency declared on a
  version range.  If your mirror is broken in this regard, so is
  ThisPAN.
+ Authentication.  If your ThisPAN instance is indexing public
  distributions, keep it public.  If it's indexing private
  distributions, keep it as private as your mirror.  If you really
  need authentication, there are several authentication middlewares
  for Plack.

# Installation

You need a CPAN mirror somewhere, accessible either via HTTP like a
regular repository or reachable locally.  This is not managed via
ThisPAN; you should use an existing tool like Pinto or minicpan to
build it.

(While re-indexing www.cpan.org is possible, please don't do it.)

This mirror ought to have a directory structure a bit like this:

```
authors
  id
    W
      WE
        WEBORAMA
          CHECKSUMS
          ThisPAN-0.001.tar.gz
    etc.
modules
  02packages.details.txt.gz
```

ThisPAN can be run entirely straight from a cloned repository,
assuming you install the dependencies first:

```shell
cd path/to/git-clone
cpanm -v --installdeps .
```

ThisPAN will need a database to properly index distribution metadata.
The official, supported flavor is SQLite 3, but anything sufficiently
DBIC-friendly *should* work.

```shell
cpanm -v DBD::SQLite DateTime::Format::SQLite
```

Create the database (the ThisPAN tarball provides a DDL file, again
for SQLite).

```shell
sqlite3 foo.db < sql/create.sql
```

Start indexing:

```shell
perl -Ilib bin/thispan-indexer \
     --mirror file:///home/fgabolde/work/localpinto/ \
     --workdir /home/fgabolde/work/local-dist-data/ \
     --tempdir /home/fgabolde/work/my-workspace/
     --state state.storable \
     --dsn dbi:SQLite:foo.db
```

This script should be started regularly, or possibly whenever a new
tarball enters your mirror.

# Web frontend deployment

To deploy the web frontend, we recommend installing your pick of a
PSGI-aware server, e.g. Starman, and the Plack tools and libraries
(`cpanm -v Plack Starman`).

You can find an example PSGI app at `examples/start-thispan-web.psgi`.
Edit it (there are quite a few paths that you should modify in there)
and save it wherever.

Create a configuration file named `config.yml` (Dancer needs that
exact filename) in the confdir you specified in your PSGI script,
using the example at `examples/config.yml`.  Documentation for this
file lives at ThisPAN::Configuration (caution: this module may or may
not have been written yet).

```shell
plackup -s Starman -p 5000 some/path/start-thispan-web.psgi \
        --pid thispan.pid -D
```

You should have a working app at
[http://localhost:5000/wherever](http://localhost:5000/wherever).
