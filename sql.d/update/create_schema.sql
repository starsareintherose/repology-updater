-- Copyright (C) 2016-2020 Dmitry Marakasov <amdmi3@amdmi3.ru>
--
-- This file is part of repology
--
-- repology is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- repology is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with repology.  If not, see <http://www.gnu.org/licenses/>.

--------------------------------------------------------------------------------
--
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- types
--------------------------------------------------------------------------------

DROP TYPE IF EXISTS metapackage_event_type CASCADE;

CREATE TYPE metapackage_event_type AS enum(
	'history_start',
	'repos_update',
	'version_update',
	'catch_up',
	'history_end'
);

DROP TYPE IF EXISTS maintainer_repo_metapackages_event_type CASCADE;

CREATE TYPE maintainer_repo_metapackages_event_type AS enum(
	'added',
	'uptodate',
	'outdated',
	'ignored',
	'removed'
);

DROP TYPE IF EXISTS repository_state CASCADE;

CREATE TYPE repository_state AS enum(
	'new',
	'active',
	'legacy',
	'readded'
);

DROP TYPE IF EXISTS run_type CASCADE;

CREATE TYPE run_type AS enum(
	'fetch',
	'parse',
	'database_push',
	'database_postprocess'
);

DROP TYPE IF EXISTS run_status CASCADE;

CREATE TYPE run_status AS enum(
	'running',
	'successful',
	'failed',
	'interrupted'
);

DROP TYPE IF EXISTS log_severity CASCADE;

CREATE TYPE log_severity AS enum(
	'notice',
	'warning',
	'error'
);

DROP TYPE IF EXISTS project_name_type CASCADE;

CREATE TYPE project_name_type AS enum(
	'name',
	'srcname',
	'binname'
);

DROP TYPE IF EXISTS problem_type CASCADE;

CREATE TYPE problem_type AS enum(
	'homepage_dead',
	'homepage_permanent_https_redirect',
	'homepage_discontinued_google',
	'homepage_discontinued_codeplex',
	'homepage_discontinued_gna',
	'homepage_discontinued_cpan',
	'cpe_unreferenced',
	'cpe_missing'
);

--------------------------------------------------------------------------------
-- functions
--------------------------------------------------------------------------------

-- Given an url, computes a digest for it which can be used to compare similar URLs
-- Rougly, "http://FOO.COM/bar/" and "https://www.foo.com/bar#baz"
-- both become "foo.com/bar", so the packages using these urls would
-- be detected as related
CREATE OR REPLACE FUNCTION simplify_url(url text) RETURNS text AS $$
BEGIN
	RETURN regexp_replace(
		regexp_replace(
			regexp_replace(
				regexp_replace(
					regexp_replace(
						regexp_replace(
							-- lowercase
							lower(url),
							-- unwrap archive.org links
							'^https?://web.archive.org/web/([0-9]{10}[^/]*/|\*/)?', ''
						),
						-- drop fragment
						'#.*$', ''
					),
					-- drop parameters
					'\?.*$', ''
				),
				-- drop trailing slash
				'/$', ''
			),
			-- drop schema
			'^https?://', ''
		),
		-- drop www.
		'^www\.', ''
	);
END;
$$ LANGUAGE plpgsql IMMUTABLE RETURNS NULL ON NULL INPUT;

-- Checks whether version set has effectively changed
CREATE OR REPLACE FUNCTION version_set_changed(old text[], new text[]) RETURNS bool AS $$
BEGIN
	RETURN
		(
			old IS NOT NULL AND
			new IS NOT NULL AND
			version_compare2(old[1], new[1]) != 0
		) OR (old IS NULL) != (new IS NULL);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Returns repositories which should be added to oldrepos to get newrepos and filters active ones
CREATE OR REPLACE FUNCTION get_added_active_repos(oldrepos text[], newrepos text[]) RETURNS text[] AS $$
BEGIN
	RETURN array((SELECT unnest(newrepos) EXCEPT SELECT unnest(oldrepos)) INTERSECT SELECT name FROM repositories WHERE state = 'active');
END;
$$ LANGUAGE plpgsql IMMUTABLE RETURNS NULL ON NULL INPUT;

-- Checks statuses and flags mask and returns whether it should be treated as ignored
CREATE OR REPLACE FUNCTION is_ignored_by_masks(statuses_mask integer, flags_mask integer) RETURNS boolean AS $$
BEGIN
	RETURN (statuses_mask & ((1<<3) | (1<<7) | (1<<8) | (1<<9) | (1<<10)))::boolean OR (flags_mask & ((1<<2) | (1<<3) | (1<<4) | (1<<5) | (1<<7)))::boolean;
END;
$$ LANGUAGE plpgsql IMMUTABLE RETURNS NULL ON NULL INPUT;

-- Similar to nullif, but with less comparison
CREATE OR REPLACE FUNCTION nullifless(value1 double precision, value2 double precision) RETURNS double precision AS $$
BEGIN
	RETURN CASE WHEN value1 < value2 THEN NULL ELSE value1 END;
END;
$$ LANGUAGE plpgsql IMMUTABLE RETURNS NULL ON NULL INPUT;

--------------------------------------------------------------------------------
-- Main packages table
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS packages CASCADE;

CREATE TABLE packages (
	id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,

	-- parsed, immutable
	repo text NOT NULL,
	family text NOT NULL,
	subrepo text,

	name text NULL,
	srcname text NULL,
	binname text NULL,
	trackname text NOT NULL,
	visiblename text NOT NULL,
	projectname_seed text NOT NULL,

	origversion text NOT NULL,
	rawversion text NOT NULL,

	arch text,

	maintainers text[],
	category text,
	comment text,
	homepage text,
	licenses text[],
	downloads text[],

	extrafields jsonb NOT NULL,

	cpe_vendor text NULL,
	cpe_product text NULL,
	cpe_edition text NULL,
	cpe_lang text NULL,
	cpe_sw_edition text NULL,
	cpe_target_sw text NULL,
	cpe_target_hw text NULL,
	cpe_other text NULL,

	-- calculated
	effname text NOT NULL,
	version text NOT NULL,
	versionclass smallint,

	flags integer NOT NULL,
	shadow bool NOT NULL,

	flavors text[],
	branch text NULL
);

CREATE INDEX ON packages(effname);

--------------------------------------------------------------------------------
-- Metapackages
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS metapackages CASCADE;

CREATE TABLE metapackages (
	id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	effname text NOT NULL,

	num_repos smallint NOT NULL DEFAULT 0,
	num_repos_nonshadow smallint NOT NULL DEFAULT 0,
	num_families smallint NOT NULL DEFAULT 0,
	num_repos_newest smallint NOT NULL DEFAULT 0,
	num_families_newest smallint NOT NULL DEFAULT 0,
	has_related boolean NOT NULL DEFAULT false,
	has_cves boolean NOT NULL DEFAULT false,

	first_seen timestamp with time zone NOT NULL DEFAULT now(),
	orphaned_at timestamp with time zone
);

-- indexes for metapackage queries
CREATE UNIQUE INDEX ON metapackages(effname);
CREATE UNIQUE INDEX metapackages_active_idx ON metapackages(effname) WHERE (num_repos_nonshadow > 0);
CREATE INDEX metapackages_effname_trgm ON metapackages USING gin (effname gin_trgm_ops) WHERE (num_repos_nonshadow > 0);
-- note that the following indexes exclude the most selective values - scan by metapackages_active_idx will be faster for these values anyway
CREATE INDEX ON metapackages(num_repos) WHERE (num_repos_nonshadow > 0 AND num_repos >= 5);
CREATE INDEX ON metapackages(num_families) WHERE (num_repos_nonshadow > 0 AND num_families >= 5);
CREATE INDEX ON metapackages(num_repos_newest) WHERE (num_repos_nonshadow > 0 AND num_repos_newest >= 1);
CREATE INDEX ON metapackages(num_families_newest) WHERE (num_repos_nonshadow > 0 AND num_families_newest >= 1);

-- index for recently_added
CREATE INDEX metapackages_recently_added_idx ON metapackages(first_seen DESC, effname) WHERE (num_repos_nonshadow > 0);

-- index for recently_removed
CREATE INDEX metapackages_recently_removed_idx ON metapackages(orphaned_at DESC, effname) WHERE (orphaned_at IS NOT NULL);

--------------------------------------------------------------------------------
-- Maintainers
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS maintainers CASCADE;

CREATE TABLE maintainers (
	id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	maintainer text NOT NULL,

	num_packages integer NOT NULL DEFAULT 0,
	num_packages_newest integer NOT NULL DEFAULT 0,
	num_packages_outdated integer NOT NULL DEFAULT 0,
	num_packages_ignored integer NOT NULL DEFAULT 0,
	num_packages_unique integer NOT NULL DEFAULT 0,
	num_packages_devel integer NOT NULL DEFAULT 0,
	num_packages_legacy integer NOT NULL DEFAULT 0,
	num_packages_incorrect integer NOT NULL DEFAULT 0,
	num_packages_untrusted integer NOT NULL DEFAULT 0,
	num_packages_noscheme integer NOT NULL DEFAULT 0,
	num_packages_rolling integer NOT NULL DEFAULT 0,
	num_packages_vulnerable integer NOT NULL DEFAULT 0,

	num_projects integer NOT NULL DEFAULT 0,
	num_projects_newest integer NOT NULL DEFAULT 0,
	num_projects_outdated integer NOT NULL DEFAULT 0,
	num_projects_problematic integer NOT NULL DEFAULT 0,
	num_projects_vulnerable integer NOT NULL DEFAULT 0,

	-- XXX: replaces *_per_repo
	-- packages, projects, projects_newest, projects_outdated, projects_problematic
	counts_per_repo jsonb,

	num_projects_per_category jsonb,

	num_repos integer NOT NULL DEFAULT 0,

	first_seen timestamp with time zone NOT NULL DEFAULT now(),
	orphaned_at timestamp with time zone
);

-- indexes for maintainer queries
CREATE UNIQUE INDEX ON maintainers(maintainer);
CREATE UNIQUE INDEX maintainers_active_idx ON maintainers(maintainer) WHERE (num_packages > 0);
CREATE INDEX maintainers_maintainer_trgm ON maintainers USING gin (maintainer gin_trgm_ops) WHERE (num_packages > 0);

-- index for recently_added
CREATE INDEX maintainers_recently_added_idx ON maintainers(first_seen DESC, maintainer) WHERE (num_packages > 0);

-- index for recently_removed
CREATE INDEX maintainers_recently_removed_idx ON maintainers(orphaned_at DESC, maintainer) WHERE (orphaned_at IS NOT NULL);

--------------------------------------------------------------------------------
-- Runs and logs
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS runs CASCADE;

CREATE TABLE runs (
	id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,

	"type" run_type NOT NULL,
	repository_id smallint,

	status run_status NOT NULL DEFAULT 'running'::run_status,
	no_changes boolean NOT NULL DEFAULT false,

	start_ts timestamp with time zone NOT NULL,
	finish_ts timestamp with time zone NULL,

	num_lines integer NULL,
	num_warnings integer NULL,
	num_errors integer NULL,

	utime interval NULL,
	stime interval NULL,
	maxrss integer NULL,
	maxrss_delta integer NULL,

	traceback text NULL
);

CREATE INDEX runs_repository_id_start_ts_idx ON runs(repository_id, start_ts DESC);
CREATE INDEX runs_repository_id_start_ts_idx_failed ON runs(repository_id, start_ts DESC) WHERE(status = 'failed'::run_status);

DROP TABLE IF EXISTS log_lines CASCADE;

CREATE TABLE log_lines (
	run_id integer NOT NULL,
	lineno integer NOT NULL,

	timestamp timestamp with time zone NOT NULL,
	severity log_severity NOT NULL,
	message text NOT NULL,

	PRIMARY KEY(run_id, lineno)
);

--------------------------------------------------------------------------------
-- Repositories
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS repositories CASCADE;

CREATE TABLE repositories (
	id smallint NOT NULL PRIMARY KEY,
	name text NOT NULL,
	state repository_state NOT NULL,

	num_packages integer NOT NULL DEFAULT 0,
	num_packages_newest integer NOT NULL DEFAULT 0,
	num_packages_outdated integer NOT NULL DEFAULT 0,
	num_packages_ignored integer NOT NULL DEFAULT 0,
	num_packages_unique integer NOT NULL DEFAULT 0,
	num_packages_devel integer NOT NULL DEFAULT 0,
	num_packages_legacy integer NOT NULL DEFAULT 0,
	num_packages_incorrect integer NOT NULL DEFAULT 0,
	num_packages_untrusted integer NOT NULL DEFAULT 0,
	num_packages_noscheme integer NOT NULL DEFAULT 0,
	num_packages_rolling integer NOT NULL DEFAULT 0,
	num_packages_vulnerable integer NOT NULL DEFAULT 0,

	num_metapackages integer NOT NULL DEFAULT 0,
	num_metapackages_unique integer NOT NULL DEFAULT 0,
	num_metapackages_newest integer NOT NULL DEFAULT 0,
	num_metapackages_outdated integer NOT NULL DEFAULT 0,
	num_metapackages_comparable integer NOT NULL DEFAULT 0,
	num_metapackages_problematic integer NOT NULL DEFAULT 0,
	num_metapackages_vulnerable integer NOT NULL DEFAULT 0,

	num_problems integer NOT NULL DEFAULT 0,
	num_maintainers integer NOT NULL DEFAULT 0,

	first_seen timestamp with time zone NOT NULL,
	last_seen timestamp with time zone NOT NULL,
	last_fetched timestamp with time zone NULL,
	last_parsed timestamp with time zone NULL,
	last_updated timestamp with time zone NULL,

	used_package_fields text[],

	ruleset_hash text NULL,

	-- metadata from config
	metadata jsonb NOT NULL,

	sortname text NOT NULL,
	"type" text NOT NULL,
	"desc" text NOT NULL,
	statsgroup text NOT NULL,
	singular text NOT NULL,
	family text NOT NULL,
	color text,
	shadow boolean NOT NULL,
	repolinks jsonb NOT NULL,
	packagelinks jsonb NOT NULL
);

CREATE UNIQUE INDEX ON repositories(name);

-- history
DROP TABLE IF EXISTS repositories_history CASCADE;

CREATE TABLE repositories_history (
	ts timestamp with time zone NOT NULL PRIMARY KEY,
	snapshot jsonb NOT NULL
);

DROP TABLE IF EXISTS repositories_history_new CASCADE;

CREATE TABLE repositories_history_new (
	repository_id smallint NOT NULL,
	ts timestamp with time zone NOT NULL,
	num_problems integer,
	num_maintainers integer,
	num_projects integer,
	num_projects_unique integer,
	num_projects_newest integer,
	num_projects_outdated integer,
	num_projects_comparable integer,
	num_projects_problematic integer,

	PRIMARY KEY(repository_id, ts)
);

--------------------------------------------------------------------------------
-- Tables binding metapackages and other entities
--------------------------------------------------------------------------------

-- per-repository
DROP TABLE IF EXISTS repo_metapackages CASCADE;

CREATE TABLE repo_metapackages (
	repository_id smallint NOT NULL,
	effname text NOT NULL,

	newest boolean NOT NULL,
	outdated boolean NOT NULL,
	problematic boolean NOT NULL,
	"unique" boolean NOT NULL,
	vulnerable boolean NOT NULL,

	PRIMARY KEY(repository_id, effname) -- best performance when clustered by pkey
);

CREATE INDEX ON repo_metapackages(effname);

-- per-category
DROP TABLE IF EXISTS category_metapackages CASCADE;

CREATE TABLE category_metapackages (
	category text NOT NULL,
	effname text NOT NULL,

	"unique" boolean NOT NULL,

	PRIMARY KEY(category, effname)
);

CREATE INDEX ON category_metapackages(effname);

-- per-maintainer
DROP TABLE IF EXISTS maintainer_metapackages CASCADE;

CREATE TABLE maintainer_metapackages (
	maintainer_id integer NOT NULL,
	effname text NOT NULL,

	newest boolean NOT NULL,
	outdated boolean NOT NULL,
	problematic boolean NOT NULL,
	vulnerable boolean NOT NULL,

	PRIMARY KEY(maintainer_id, effname)
);

CREATE INDEX ON maintainer_metapackages(effname);

-- per-maintainer AND repo

-- XXX: as it can be guessed by the name, this mostly duplicates
-- maintainer_repo_metapackages table. I'm residing to this imperfect
-- solution in order to fix #655 faster and not affect feeds in any
-- way, since using existing maintainer_repo_metapackages for both
-- history generation and project queries. After switching to delta
-- updates, the another table would not be needed, this can be renamed
-- to maintainer_repo_metapackages and used for queries only.
DROP TABLE IF EXISTS maintainer_and_repo_metapackages CASCADE;

CREATE TABLE maintainer_and_repo_metapackages (
	maintainer_id integer NOT NULL,
	repository_id smallint NOT NULL,
	effname text NOT NULL,

	newest boolean NOT NULL,
	outdated boolean NOT NULL,
	problematic boolean NOT NULL,
	vulnerable boolean NOT NULL,

	PRIMARY KEY(maintainer_id, repository_id, effname)
);

CREATE INDEX ON maintainer_and_repo_metapackages(effname);

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- project events
DROP TABLE IF EXISTS metapackages_events CASCADE;

CREATE TABLE metapackages_events (
	effname text NOT NULL,
	ts timestamp with time zone NOT NULL,
	type metapackage_event_type NOT NULL,
	data jsonb NOT NULL
);

CREATE INDEX ON metapackages_events(effname, ts DESC);

-- maintainer events
DROP TABLE IF EXISTS maintainer_repo_metapackages_events CASCADE;

CREATE TABLE maintainer_repo_metapackages_events (
	id integer GENERATED BY DEFAULT AS IDENTITY,

	maintainer_id integer NOT NULL,
	repository_id smallint NOT NULL,

	ts timestamp with time zone NOT NULL,

	metapackage_id integer NOT NULL,
	type maintainer_repo_metapackages_event_type NOT NULL,
	data jsonb NOT NULL
);

CREATE INDEX ON maintainer_repo_metapackages_events(maintainer_id, repository_id, ts DESC);

-- repository events
DROP TABLE IF EXISTS repository_events CASCADE;

CREATE TABLE repository_events (
	id integer GENERATED BY DEFAULT AS IDENTITY,

	repository_id smallint NOT NULL,

	ts timestamp with time zone NOT NULL,

	metapackage_id integer NOT NULL,
	type maintainer_repo_metapackages_event_type NOT NULL,
	data jsonb NOT NULL
);

CREATE INDEX ON repository_events(repository_id, ts DESC);

--------------------------------------------------------------------------------
-- Statistics
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS statistics CASCADE;

CREATE TABLE statistics (
	num_packages integer NOT NULL DEFAULT 0,
	num_metapackages integer NOT NULL DEFAULT 0,
	num_problems integer NOT NULL DEFAULT 0,
	num_maintainers integer NOT NULL DEFAULT 0,
	num_urls_checked integer NOT NULL DEFAULT 0
);

INSERT INTO statistics VALUES(DEFAULT);

-- statistics_history
DROP TABLE IF EXISTS statistics_history CASCADE;

CREATE TABLE statistics_history (
	ts timestamp with time zone NOT NULL PRIMARY KEY,
	snapshot jsonb NOT NULL
);

--------------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS links CASCADE;

CREATE TABLE links (
	url text NOT NULL PRIMARY KEY,
	first_extracted timestamp with time zone NOT NULL DEFAULT now(),
	orphaned_since timestamp with time zone,
	next_check timestamp with time zone NOT NULL DEFAULT now(),
	last_checked timestamp with time zone,

	ipv4_last_success timestamp with time zone,
	ipv4_last_failure timestamp with time zone,
	ipv4_success boolean,
	ipv4_status_code smallint,
	ipv4_permanent_redirect_target text,

	ipv6_last_success timestamp with time zone,
	ipv6_last_failure timestamp with time zone,
	ipv6_success boolean,
	ipv6_status_code smallint,
	ipv6_permanent_redirect_target text
);

CREATE INDEX ON links(next_check);

--------------------------------------------------------------------------------
-- Problems
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS problems CASCADE;

CREATE TABLE problems (
	package_id integer NOT NULL,
	repo text NOT NULL,
	name text NOT NULL,
	effname text NOT NULL,
	maintainer text,
	"type" problem_type NOT NULL,
	data jsonb NULL
);

CREATE INDEX ON problems(effname);
CREATE INDEX ON problems(repo, effname);
CREATE INDEX ON problems(maintainer);

--------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS reports CASCADE;

CREATE TABLE IF NOT EXISTS reports (
	id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	created timestamp with time zone NOT NULL,
	updated timestamp with time zone NOT NULL,
	client text,
	effname text NOT NULL,
	need_verignore boolean NOT NULL,
	need_split boolean NOT NULL,
	need_merge boolean NOT NULL,
	comment text,
	reply text,
	accepted boolean
);

CREATE INDEX ON reports(effname, created DESC);
CREATE INDEX ON reports(created DESC) WHERE (accepted IS NULL);
CREATE INDEX ON reports(updated DESC);

--------------------------------------------------------------------------------
-- Url relations
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS url_relations_all CASCADE;

CREATE TABLE url_relations_all (
	metapackage_id integer NOT NULL,
	urlhash bigint NOT NULL
);

CREATE INDEX ON url_relations_all(metapackage_id);

DROP TABLE IF EXISTS url_relations CASCADE;

CREATE TABLE url_relations (
	metapackage_id integer NOT NULL,
	urlhash bigint NOT NULL
);

CREATE UNIQUE INDEX ON url_relations(metapackage_id, urlhash);
CREATE UNIQUE INDEX ON url_relations(urlhash, metapackage_id);

--------------------------------------------------------------------------------
-- Redirects
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS project_redirects CASCADE;

CREATE TABLE project_redirects (
	project_id integer NOT NULL,
	repository_id smallint NOT NULL,
	is_actual boolean NOT NULL,
	trackname text NOT NULL
);

CREATE UNIQUE INDEX ON project_redirects (project_id, repository_id, trackname);
CREATE INDEX ON project_redirects (repository_id, trackname) WHERE is_actual;

DROP TABLE IF EXISTS project_redirects_manual CASCADE;

CREATE TABLE project_redirects_manual (
	oldname text NOT NULL,
	newname text NOT NULL,
	PRIMARY KEY(oldname, newname)
);

CREATE INDEX ON project_redirects_manual(newname);

--------------------------------------------------------------------------------
-- Hashes
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS project_hashes CASCADE;

CREATE TABLE project_hashes (
	effname text NOT NULL PRIMARY KEY,
	hash bigint NOT NULL
);

--------------------------------------------------------------------------------
-- Tracknames
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS repo_tracks CASCADE;

CREATE TABLE repo_tracks (
	repository_id smallint NOT NULL,
	refcount smallint NOT NULL,
	start_ts timestamp with time zone NOT NULL DEFAULT now(),
	restart_ts timestamp with time zone,
	end_ts timestamp with time zone,
	trackname text NOT NULL,

	PRIMARY KEY(repository_id, trackname)
);

--------------------------------------------------------------------------------
-- Trackname versions
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS repo_track_versions CASCADE;

CREATE TABLE repo_track_versions (
	repository_id smallint NOT NULL,
	refcount smallint NOT NULL,
	trackname text NOT NULL,
	version text NOT NULL,
	start_ts timestamp with time zone NOT NULL DEFAULT now(),
	end_ts timestamp with time zone,
	any_statuses integer NOT NULL DEFAULT 0,
	any_flags integer NOT NULL DEFAULT 0,

	PRIMARY KEY(repository_id, trackname, version)
);

--------------------------------------------------------------------------------
-- Project releases
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS project_releases CASCADE;

CREATE TABLE project_releases (
	effname text NOT NULL,
	version text NOT NULL,
	start_ts timestamp with time zone,
	trusted_start_ts timestamp with time zone,
	end_ts timestamp with time zone,

	PRIMARY KEY(effname, version)
);

--------------------------------------------------------------------------------
-- Project turnover
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS project_turnover CASCADE;

CREATE TABLE project_turnover (
	effname text NOT NULL,
	delta smallint NOT NULL,
	ts timestamp with time zone NOT NULL DEFAULT now(),
	family text NOT NULL
);

--------------------------------------------------------------------------------
-- Project names
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS project_names CASCADE;

CREATE TABLE project_names (
	project_id integer NOT NULL,
	repository_id smallint NOT NULL,
	name_type project_name_type NOT NULL,
	name text NOT NULL
);

CREATE INDEX ON project_names(project_id);
CREATE INDEX ON project_names(name, repository_id);

--------------------------------------------------------------------------------
-- Complete repository/projects/maintainers listing
--------------------------------------------------------------------------------
-- this is similar to maintainer_repo_metapackages, however
-- is more lightweight by not needing to store effname, flags
-- and some indexes; it also covers all projects, including
-- shadow ones

DROP TABLE IF EXISTS repository_project_maintainers CASCADE;

CREATE TABLE repository_project_maintainers (
	maintainer_id integer NOT NULL,
	project_id integer NOT NULL,
	repository_id smallint NOT NULL
);

CREATE INDEX ON repository_project_maintainers(project_id);

--------------------------------------------------------------------------------
-- CPE data
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS manual_cpes CASCADE;

CREATE TABLE manual_cpes (
	effname text NOT NULL,
	cpe_vendor text NOT NULL,
	cpe_product text NOT NULL,
	cpe_edition text NOT NULL,
	cpe_lang text NOT NULL,
	cpe_sw_edition text NOT NULL,
	cpe_target_sw text NOT NULL,
	cpe_target_hw text NOT NULL,
	cpe_other text NOT NULL
);

CREATE UNIQUE INDEX ON manual_cpes(effname, cpe_product, cpe_vendor, cpe_edition, cpe_lang, cpe_sw_edition, cpe_target_sw, cpe_target_hw, cpe_other);
CREATE INDEX ON manual_cpes(cpe_product, cpe_vendor);


DROP TABLE IF EXISTS project_cpe CASCADE;

CREATE TABLE project_cpe (
	effname text NOT NULL,
	cpe_vendor text,
	cpe_product text NOT NULL,
	cpe_edition text,
	cpe_lang text,
	cpe_sw_edition text,
	cpe_target_sw text,
	cpe_target_hw text,
	cpe_other text
);

CREATE INDEX ON project_cpe(effname);
CREATE INDEX ON project_cpe(cpe_product, cpe_vendor);

--------------------------------------------------------------------------------
-- vulnerability data
--------------------------------------------------------------------------------

-- update status of vulnerability sources
DROP TABLE IF EXISTS vulnerability_sources CASCADE;

CREATE TABLE vulnerability_sources (
	url text NOT NULL PRIMARY KEY,
	etag text NULL,
	last_update timestamp with time zone NULL,
	total_updates integer NOT NULL DEFAULT 0,
	"type" text NOT NULL
);

-- raw cve information
DROP TABLE IF EXISTS cves CASCADE;

CREATE TABLE cves (
	cve_id text NOT NULL PRIMARY KEY,
	published timestamp with time zone NOT NULL,
	last_modified timestamp with time zone NOT NULL,
	matches jsonb,
	cpe_pairs text[]
);

CREATE INDEX ON cves USING gin (cpe_pairs);

-- cpe dictionary
DROP TABLE IF EXISTS cpe_dictionary CASCADE;

CREATE TABLE cpe_dictionary (
	cpe_vendor text NOT NULL,
	cpe_product text NOT NULL,
	cpe_edition text NOT NULL,
	cpe_lang text NOT NULL,
	cpe_sw_edition text NOT NULL,
	cpe_target_sw text NOT NULL,
	cpe_target_hw text NOT NULL,
	cpe_other text NOT NULL
);

CREATE UNIQUE INDEX ON cpe_dictionary(cpe_product, cpe_vendor, cpe_edition, cpe_lang, cpe_sw_edition, cpe_target_sw, cpe_target_hw, cpe_other);

-- cpe updates queue (used to force updates of related projects)
DROP TABLE IF EXISTS cpe_updates CASCADE;

CREATE TABLE cpe_updates (
	cpe_vendor text NOT NULL,
	cpe_product text NOT NULL
);

-- optimized vulnerable version ranges for lookups
DROP TABLE IF EXISTS vulnerable_cpes CASCADE;

CREATE TABLE vulnerable_cpes (
	cpe_vendor text NOT NULL,
	cpe_product text NOT NULL,
	cpe_edition text NOT NULL,
	cpe_lang text NOT NULL,
	cpe_sw_edition text NOT NULL,
	cpe_target_sw text NOT NULL,
	cpe_target_hw text NOT NULL,
	cpe_other text NOT NULL,

	start_version text NULL,
	end_version text NULL,
	start_version_excluded boolean NOT NULL DEFAULT false,
	end_version_excluded boolean NOT NULL DEFAULT false
);

CREATE INDEX ON vulnerable_cpes(cpe_product, cpe_vendor);

DROP VIEW IF EXISTS vulnerable_projects CASCADE;

CREATE VIEW vulnerable_projects AS
	SELECT
		effname,

		vulnerable_cpes.cpe_product,
		vulnerable_cpes.cpe_vendor,
		vulnerable_cpes.cpe_edition,
		vulnerable_cpes.cpe_lang,
		vulnerable_cpes.cpe_sw_edition,
		vulnerable_cpes.cpe_target_sw,
		vulnerable_cpes.cpe_target_hw,
		vulnerable_cpes.cpe_other,

		start_version,
		end_version,
		start_version_excluded,
		end_version_excluded
    FROM vulnerable_cpes INNER JOIN manual_cpes ON
		vulnerable_cpes.cpe_product = manual_cpes.cpe_product AND
		vulnerable_cpes.cpe_vendor = manual_cpes.cpe_vendor AND
		coalesce(nullif(vulnerable_cpes.cpe_edition, '*') = nullif(manual_cpes.cpe_edition, '*'), TRUE) AND
		coalesce(nullif(vulnerable_cpes.cpe_lang, '*') = nullif(manual_cpes.cpe_lang, '*'), TRUE) AND
		coalesce(nullif(vulnerable_cpes.cpe_sw_edition, '*') = nullif(manual_cpes.cpe_sw_edition, '*'), TRUE) AND
		coalesce(nullif(vulnerable_cpes.cpe_target_sw, '*') = nullif(manual_cpes.cpe_target_sw, '*'), TRUE) AND
		coalesce(nullif(vulnerable_cpes.cpe_target_hw, '*') = nullif(manual_cpes.cpe_target_hw, '*'), TRUE) AND
		coalesce(nullif(vulnerable_cpes.cpe_other, '*') = nullif(manual_cpes.cpe_other, '*'), TRUE);
