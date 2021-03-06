CREATE TABLE user (
     user_id int unsigned not null auto_increment primary key
    ,login varchar(255) not null
    ,name varchar(255) default null
    ,gravatar_id varchar(255) default null
    ,github_response text
    ,ctime        int unsigned not null
    ,mtime        int unsigned not null
    ,unique (login)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE i_use_this (
     user_id       int unsigned not null
    ,dist_name    varchar(255) not null
    ,dist_version varchar(255) not null
    ,body         text
    ,ctime        int unsigned not null
    ,mtime        int unsigned not null
    ,UNIQUE (user_id, dist_name)
    ,INDEX (dist_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS dist (
     dist_id int unsigned not null AUTO_INCREMENT PRIMARY KEY
    ,author   varchar(255) not null
    ,name     varchar(255) not null
    ,version  varchar(255) not null
    ,path     varchar(255)
    ,abstract varchar(255)
    ,resources_json text
    ,has_manifest tinyint(1) not null default 0
    ,has_makefile_pl tinyint(1) not null default 0
    ,has_build_pl tinyint(1) not null default 0
    ,has_changes tinyint(1) not null default 0
    ,has_change_log tinyint(1) not null default 0
    ,has_meta_yml tinyint(1) not null default 0
    ,has_meta_json tinyint(1) not null default 0
    ,requires text
    ,released int unsigned not null
    ,old      tinyint(1) not null default 0
    ,authorized tinyint(1) not null default 1
    ,UNIQUE idx_author_name_version (author, name, version)
    ,INDEX  name (name) -- search by name for removing fts index
) engine=InnoDB DEFAULT charset=UTF8;
create index dist_released ON dist (released);
-- alter table dist add authorized tinyint(1) not null default 1;
-- alter table file add authorized tinyint(1) not null default 1;

CREATE TABLE IF NOT EXISTS file (
     file_id     int unsigned not null AUTO_INCREMENT PRIMARY KEY
    ,path        varchar(255) not null
    ,dist_id     int unsigned not null
    ,package     varchar(255)
    ,description varchar(255)
    ,html        text
    ,authorized tinyint(1) not null default 1
    ,UNIQUE(dist_id, path)
    ,INDEX (package)
) engine=InnoDB DEFAULT charset=UTF8;
ALTER TABLE file ADD FOREIGN KEY (dist_id) REFERENCES dist(dist_id) ON DELETE CASCADE;

CREATE TABLE IF NOT EXISTS changes (
     changes_id  int unsigned not null AUTO_INCREMENT PRIMARY KEY
    ,dist_id     int unsigned not null
    ,version     varchar(255) not null
    ,body        text
    ,UNIQUE(dist_id, version)
) engine=InnoDB DEFAULT charset=UTF8;
ALTER TABLE changes ADD FOREIGN KEY (dist_id) REFERENCES dist(dist_id) ON DELETE CASCADE;

-- authors/01mailrc.txt.gz
CREATE TABLE IF NOT EXISTS meta_author (
     pause_id    varchar(255) not null PRIMARY KEY
    ,fullname    varchar(255) not null
    ,email       varchar(255) not null
    ,gravatar_id varchar(255) not null
) engine=InnoDB DEFAULT charset=UTF8;

-- modules/02packages.details.txt.gz
CREATE TABLE IF NOT EXISTS meta_packages (
     package      varchar(255) BINARY not null PRIMARY KEY
    ,version      varchar(255) BINARY not null
    ,path         varchar(255) BINARY not null
    ,pause_id     varchar(255) BINARY NOT NULL
    ,dist_name    varchar(255) BINARY NOT NULL
    ,dist_version varchar(255) BINARY NOT NULL
    ,dist_version_numified varchar(255) BINARY NOT NULL
) engine=InnoDB DEFAULT charset=UTF8;
alter table meta_packages add index (pause_id, dist_name, dist_version);

-- from http://devel.cpantesters.org/uploads/uploads.db.bz2
-- select pkg.dist_name, MAX(pkg.dist_version), upl.released from meta_packages as pkg left join meta_uploads as upl on (pkg.dist_name=upl.dist_name AND pkg.pause_id=upl.pause_id) where pkg.pause_id="TOKUHIROM" GROUP BY pkg.dist_name;
CREATE TABLE IF NOT EXISTS meta_uploads (
    type          varchar(255) binary not null
    ,pause_id     varchar(255) binary not null
    ,dist_name    varchar(255) binary not null
    ,dist_version varchar(255) binary not null
    ,filename     varchar(255) binary not null
    ,released     int unsigned        not null -- 'unix time'
    ,PRIMARY KEY (pause_id, dist_name, dist_version)
) engine=InnoDB DEFAULT charset=UTF8;
-- alter table meta_uploads add type          varchar(255) binary not null before pause_id;

-- from http://cpan.yimg.com/modules/06perms.txt
--     best-permission is one of "m" for "modulelist", "f" for
--    "first-come", "c" for "co-maint"
CREATE TABLE meta_perms (
    package varchar(255) binary not null,
    pause_id varchar(255) binary not null,
    permission char(1) binary not null,
    INDEX package (package)
) engine=InnoDB DEFAULT charset=utf8;

-- 132673|cpan
-- 939737|fail
-- 1603|fail:invalid
-- 194270|na
-- 859|na:invalid
-- 8472276|pass
-- 428762|unknown
-- 462|unknown:invalid
CREATE TABLE cpanstats (
    guid char(36) NOT NULL,
    state         VARCHAR(255),
    postdate      VARCHAR(255),
    tester        VARCHAR(255),
    dist          VARCHAR(255),
    version       VARCHAR(255),
    platform      VARCHAR(255),
    perl          VARCHAR(255),
    osname        VARCHAR(255),
    osvers        VARCHAR(255),
    date          VARCHAR(255),
    type int(2) default 0,
    PRIMARY KEY (guid)
) engine=InnoDB DEFAULT charset=utf8;
CREATE INDEX distver ON cpanstats (dist, version);

CREATE TABLE cpanstats_summary (
    dist    VARCHAR(255),
    version VARCHAR(255),
    state   VARCHAR(255),
    cnt     INTEGER UNSIGNED NOT NULL,
    PRIMARY KEY (dist, version, state)
) engine=InnoDB DEFAULT charset=utf8;

