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
perl -Ilib bin/feed-the-webopan.pl \
     --mirror file:///home/fgabolde/work/localpinto/ \
     --workdir /home/fgabolde/work/local-dist-data/ \
     --resume state.storable \
     --base-url http://localhost:5000/webopan/ \
     --dsn dbi:SQLite:foo.db
```

This script should be started regularly, or possibly whenever a new
tarball enters your mirror.

Start the server:

```shell
plackup -s Starman -p 5000 bin/whatever.psgi --pid thispan.pid -D
```
