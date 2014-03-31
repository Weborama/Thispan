CREATE TABLE module (
    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    name                      VARCHAR UNIQUE NOT NULL,
    distribution              INTEGER NOT NULL REFERENCES distribution(id) ON UPDATE CASCADE ON DELETE CASCADE,
    rendered_pod_path         VARCHAR UNIQUE
);

CREATE TABLE distribution (
    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    name                      VARCHAR UNIQUE NOT NULL,
    version                   VARCHAR,
    changes_path              VARCHAR UNIQUE,
    metadata_json_blob        VARCHAR NOT NULL,
    tarball_path              VARCHAR UNIQUE NOT NULL
);

CREATE TABLE relationship (
    parent                    INTEGER NOT NULL REFERENCES distribution(id) ON UPDATE CASCADE ON DELETE CASCADE,
    child                     INTEGER NOT NULL REFERENCES distribution(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    module                    INTEGER NOT NULL REFERENCES module(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    phase                     VARCHAR NOT NULL,
    type                      VARCHAR NOT NULL,
    version                   VARCHAR NOT NULL,
    PRIMARY KEY (parent, child, module, phase)
);
