package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Postgres extension bundles.
//
// Each (extension × Postgres major) is published as its own ENGINE, keyed
// pgext-<name>-pg<major>, in the same mirror as postgres itself — so doze's
// existing fetcher, digest checks and doze.lock pins work on it unchanged. The
// catalog lists each extension once (versions.yaml `extensions:`); dzb expands
// it into those engine entries at load time, so plan, manifest, engines and
// latest need no second list. The contract this implements is
// doze/docs/design/postgres-extensions.md, "The contract between the build and
// the module".

// pgextPrefix starts every extension-bundle engine key.
const pgextPrefix = "pgext-"

// extSpec is one extension's catalog entry, read verbatim from versions.yaml.
// It is the only place doze describes the extension: the build reads the
// build fields, and the signed add-on index (addons.go) publishes the rest.
type extSpec struct {
	// Wave is the rollout wave (1 simple, 2 heavy). Only the waves in
	// versions.yaml extension_waves are expanded into engines and indexed.
	Wave int `yaml:"wave"`
	// Description is one line: what the extension is for.
	Description string `yaml:"description"`
	// Homepage is the upstream project.
	Homepage string `yaml:"homepage"`
	// Aliases are friendlier names for the same extension (pgvector).
	Aliases []string `yaml:"aliases"`
	// MayPreload names libraries that may be preloaded (a background worker);
	// the user opts in through settings.shared_preload_libraries.
	MayPreload []string `yaml:"may_preload"`
	// Provides are further CREATE EXTENSION names inside the same bundle,
	// each with what it requires (postgis_raster needs postgis).
	Provides map[string][]string `yaml:"provides"`
	// Note is anything a reader should know (a licence caveat).
	Note string `yaml:"note"`
	// Repo is the upstream git repository the bundle is built from.
	Repo string `yaml:"repo"`
	// Ref is the source-ref template. Placeholders: {v} (version verbatim),
	// {v_} (dots->underscores), {pg} (the Postgres major). Default "{v}".
	Ref string `yaml:"ref"`
	// Subdir is where the extension's Makefile (or Cargo.toml) lives inside
	// the repo, when not at its root (pgmq: pgmq-extension).
	Subdir string `yaml:"subdir"`
	// Build is the build system: "pgxs" (default) or "pgrx" (Rust).
	Build string `yaml:"build"`
	// License is the licence as shipped (SPDX where there is one), copied
	// into bundle.json and the add-on index.
	License string `yaml:"license"`
	// PG lists the Postgres majors every version in Versions supports.
	PG []int `yaml:"pg"`
	// Versions are built for every major in PG (those without a Lines entry).
	Versions []string `yaml:"versions"`
	// Lines gives a major its own release line — for extensions that cut one
	// release series per Postgres major (pgaudit 1.6.x is PG14 only, 17.x is
	// PG17 only; pg_hint_plan likewise). A major listed here uses ITS versions
	// (and ref, if set) instead of the top-level ones. Majors here need not
	// appear in PG.
	Lines map[int]extLine `yaml:"lines"`
	// Preload names the libraries that must be in shared_preload_libraries.
	Preload []string `yaml:"preload"`
	// Settings are postgresql.conf settings the extension needs. Values may
	// use the module's placeholders ({db} = the instance's database).
	Settings map[string]string `yaml:"settings"`
	// Env is environment the server needs ({root} = the bundle's install root).
	Env map[string]string `yaml:"env"`
	// Requires lists extensions (by CREATE EXTENSION name) that must be
	// created first, possibly from other bundles.
	Requires []string `yaml:"requires"`
}

// extLine is one Postgres major's own release line.
type extLine struct {
	Versions []string `yaml:"versions"`
	Ref      string   `yaml:"ref"`
}

// extEngine is what an expanded pgext-* engine knows about its extension.
type extEngine struct {
	Name    string
	PGMajor int
	Spec    extSpec
}

func pgextEngineKey(name string, major int) string {
	return fmt.Sprintf("%s%s-pg%d", pgextPrefix, name, major)
}

func isPgext(engine string) bool { return strings.HasPrefix(engine, pgextPrefix) }

// majors returns every Postgres major the extension is built for, sorted.
func (s extSpec) majors() []int {
	seen := map[int]bool{}
	for _, m := range s.PG {
		seen[m] = true
	}
	for m := range s.Lines {
		seen[m] = true
	}
	out := make([]int, 0, len(seen))
	for m := range seen {
		out = append(out, m)
	}
	sort.Ints(out)
	return out
}

// forMajor returns the versions and ref template built for one major.
func (s extSpec) forMajor(major int) (versions []string, ref string) {
	versions, ref = s.Versions, s.Ref
	if l, ok := s.Lines[major]; ok {
		versions = l.Versions
		if l.Ref != "" {
			ref = l.Ref
		}
	}
	if ref == "" {
		ref = "{v}"
	}
	return versions, strings.ReplaceAll(ref, "{pg}", strconv.Itoa(major))
}

// expandExtensions validates the extensions catalog and adds one engine per
// (extension, major) to c.Engines. Versions are the extension's own, verbatim;
// the index keys them two-part (0.8.7 -> "0.8") so a module resolves a line.
func (c *config) expandExtensions() error {
	if len(c.Extensions) == 0 {
		return nil
	}
	if c.Engines == nil {
		c.Engines = map[string]engineSpec{}
	}
	if len(c.ExtensionWaves) == 0 {
		return fmt.Errorf("extension_waves is required: the waves that are built and published")
	}
	c.pgext = map[string]extEngine{}
	pgMajors := c.postgresMajors()
	names := make([]string, 0, len(c.Extensions))
	for n := range c.Extensions {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		spec := c.Extensions[name]
		if err := validateExt(name, spec); err != nil {
			return err
		}
		// A wave that is not built is validated above but never becomes an
		// engine: nothing plans, builds, publishes or indexes it.
		if !c.waveBuilt(spec.Wave) {
			continue
		}
		for _, major := range spec.majors() {
			if len(pgMajors) > 0 && !pgMajors[major] {
				return fmt.Errorf("extension %s: Postgres %d is not in the postgres catalog", name, major)
			}
			versions, ref := spec.forMajor(major)
			if len(versions) == 0 {
				return fmt.Errorf("extension %s: no versions for Postgres %d", name, major)
			}
			key := pgextEngineKey(name, major)
			if _, dup := c.Engines[key]; dup {
				return fmt.Errorf("extension %s: engine %s is already declared", name, key)
			}
			c.Engines[key] = engineSpec{
				Versions:   append([]string(nil), versions...),
				Ref:        ref,
				MajorParts: 2,
			}
			c.pgext[key] = extEngine{Name: name, PGMajor: major, Spec: spec}
		}
	}
	return nil
}

func validateExt(name string, s extSpec) error {
	if name == "" || strings.ContainsAny(name, " /") {
		return fmt.Errorf("extension %q: not a CREATE EXTENSION name", name)
	}
	if s.Repo == "" {
		return fmt.Errorf("extension %s: repo is required", name)
	}
	if s.License == "" {
		return fmt.Errorf("extension %s: license is required", name)
	}
	if s.Wave < 1 {
		return fmt.Errorf("extension %s: wave is required (1, 2, …)", name)
	}
	if s.Description == "" {
		return fmt.Errorf("extension %s: description is required", name)
	}
	if s.Homepage == "" {
		return fmt.Errorf("extension %s: homepage is required", name)
	}
	switch s.Build {
	case "", "pgxs", "pgrx":
	default:
		return fmt.Errorf("extension %s: unknown build %q (want pgxs or pgrx)", name, s.Build)
	}
	if len(s.majors()) == 0 {
		return fmt.Errorf("extension %s: no Postgres majors (pg or lines)", name)
	}
	if len(s.PG) > 0 && len(s.Versions) == 0 {
		for _, m := range s.PG {
			if _, ok := s.Lines[m]; !ok {
				return fmt.Errorf("extension %s: pg lists %d but there are no top-level versions", name, m)
			}
		}
	}
	for _, v := range s.Versions {
		if strings.ContainsAny(v, " /") || v == "" {
			return fmt.Errorf("extension %s: bad version %q", name, v)
		}
	}
	return nil
}

// waveBuilt reports whether a catalog wave is in the built set.
func (c *config) waveBuilt(w int) bool {
	for _, b := range c.ExtensionWaves {
		if b == w {
			return true
		}
	}
	return false
}

// builtExtensions returns the names of the catalogued extensions in the built
// set (extension_waves), sorted.
func (c *config) builtExtensions() []string {
	var out []string
	for n, s := range c.Extensions {
		if c.waveBuilt(s.Wave) {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

// postgresMajors is the set of majors the postgres catalog ships, so an
// extension can't be catalogued for a major doze has no Postgres tree for.
func (c *config) postgresMajors() map[int]bool {
	out := map[int]bool{}
	for _, v := range c.Engines["postgres"].Versions {
		if m, err := strconv.Atoi(majorKey(v, 1)); err == nil {
			out[m] = true
		}
	}
	return out
}

// buildMinor is the Postgres version an extension bundle for a major is built
// against: the OLDEST minor doze ships for it. Postgres keeps the ABI stable
// within a major in the forward direction only — a module built against x.0
// loads on x.N, but one built against x.N may use a symbol x.0 lacks — so the
// oldest minor is the only base that serves every pinned minor.
func (c *config) buildMinor(major int) (string, error) {
	spec := c.Engines["postgres"]
	var best string
	for _, v := range spec.Versions {
		if majorKey(v, 1) != strconv.Itoa(major) {
			continue
		}
		if best == "" || versionLess(v, best) {
			best = v
		}
	}
	if best == "" {
		return "", fmt.Errorf("no postgres %d in the catalog", major)
	}
	return spec.archiveVersion(best), nil
}

// newestMinor is the newest catalogued minor of a major — what most users run,
// so bundles are verified against it as well as against the build base.
func (c *config) newestMinor(major int) (string, error) {
	spec := c.Engines["postgres"]
	var best string
	for _, v := range spec.Versions {
		if majorKey(v, 1) == strconv.Itoa(major) && (best == "" || versionLess(best, v)) {
			best = v
		}
	}
	if best == "" {
		return "", fmt.Errorf("no postgres %d in the catalog", major)
	}
	return spec.archiveVersion(best), nil
}

// bundleManifest is bundle.json: the contract's fields, in the contract's
// order, every one always present (empty list/map rather than null).
type bundleManifest struct {
	Name     string            `json:"name"`
	Version  string            `json:"version"`
	PGMajor  int               `json:"pg_major"`
	Preload  []string          `json:"preload"`
	Settings map[string]string `json:"settings"`
	Env      map[string]string `json:"env"`
	Requires []string          `json:"requires"`
	License  string            `json:"license"`
	Source   string            `json:"source"`
	Recipe   string            `json:"recipe"`
}

func orEmpty[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func orEmptyMap(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

// pgextLookup finds the expanded engine for (name, major) and checks the
// version is catalogued for it — a bundle is only ever built for what the
// catalog lists, so a typo fails here instead of publishing a stray archive.
func (c *config) pgextLookup(name, version string, major int) (extEngine, string, error) {
	key := pgextEngineKey(name, major)
	e, ok := c.pgext[key]
	if !ok {
		return extEngine{}, "", fmt.Errorf("no extension %s for Postgres %d in versions.yaml", name, major)
	}
	versions, ref := e.Spec.forMajor(major)
	for _, v := range versions {
		if v == version {
			return e, engineSpec{Ref: ref}.ref(v), nil
		}
	}
	return extEngine{}, "", fmt.Errorf("%s: version %s is not catalogued (have %s)", key, version, strings.Join(versions, ", "))
}

func (c *config) bundleJSON(name, version string, major int, recipe string) ([]byte, error) {
	e, ref, err := c.pgextLookup(name, version, major)
	if err != nil {
		return nil, err
	}
	m := bundleManifest{
		Name: name, Version: version, PGMajor: major,
		Preload:  orEmpty(e.Spec.Preload),
		Settings: orEmptyMap(e.Spec.Settings),
		Env:      orEmptyMap(e.Spec.Env),
		Requires: orEmpty(e.Spec.Requires),
		License:  e.Spec.License,
		Source:   e.Spec.Repo + "@" + ref,
		Recipe:   recipe,
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(m); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// shellQuote single-quotes s for eval in bash.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// pgextEnv is what recipes/pgext/build.sh evals: the build inputs, as shell
// assignments, so the recipe never parses YAML.
func (c *config) pgextEnv(name, version string, major int) (string, error) {
	e, ref, err := c.pgextLookup(name, version, major)
	if err != nil {
		return "", err
	}
	base, err := c.buildMinor(major)
	if err != nil {
		return "", err
	}
	newest, err := c.newestMinor(major)
	if err != nil {
		return "", err
	}
	build := e.Spec.Build
	if build == "" {
		build = "pgxs"
	}
	vars := [][2]string{
		{"PGEXT_ENGINE", pgextEngineKey(name, major)},
		{"PGEXT_NAME", name},
		{"PGEXT_VERSION", version},
		{"PGEXT_PG_MAJOR", strconv.Itoa(major)},
		{"PGEXT_REPO", e.Spec.Repo},
		{"PGEXT_REF", ref},
		{"PGEXT_SUBDIR", e.Spec.Subdir},
		{"PGEXT_BUILD", build},
		{"PGEXT_PRELOAD", strings.Join(e.Spec.Preload, ",")},
		{"PGEXT_REQUIRES", strings.Join(e.Spec.Requires, " ")},
		{"PGEXT_PG_BASE", base},
		{"PGEXT_PG_NEWEST", newest},
	}
	var b strings.Builder
	for _, kv := range vars {
		fmt.Fprintf(&b, "%s=%s\n", kv[0], shellQuote(kv[1]))
	}
	return b.String(), nil
}

// pgtreeArtifact resolves a published postgres archive (full version, triple)
// from the postgres index: "<url> <sha256>".
func pgtreeArtifact(full, triple string) (string, string, error) {
	loc := os.Getenv("DZB_POSTGRES_INDEX_URL")
	if loc == "" {
		repo := os.Getenv("GITHUB_REPOSITORY")
		if repo == "" {
			repo = "doze-dev/doze-binaries"
		}
		loc = fmt.Sprintf("https://github.com/%s/releases/download/postgres/index.yaml", repo)
	}
	body, found, err := fetchIndex(loc)
	if err != nil {
		return "", "", err
	}
	if !found {
		return "", "", fmt.Errorf("no postgres index at %s", loc)
	}
	var idx manifest
	if err := yaml.Unmarshal(body, &idx); err != nil {
		return "", "", fmt.Errorf("parsing postgres index: %w", err)
	}
	pg := idx.Engines["postgres"]
	if pg == nil {
		return "", "", fmt.Errorf("postgres index at %s has no postgres engine", loc)
	}
	a, ok := pg.Artifacts[full][triple]
	if !ok {
		return "", "", fmt.Errorf("postgres %s is not published for %s (the extension build needs that tree)", full, triple)
	}
	return a.URL, a.SHA256, nil
}

// runPgext is `dzb pgext <env|bundle-json|pgtree> ...`, the data the pgext
// recipe needs, so the recipe never parses the catalog itself.
//
//	dzb pgext env <name> <version> <pg_major>          shell assignments to eval
//	dzb pgext bundle-json <name> <version> <pg_major>  the bundle.json contents
//	dzb pgext pgtree <base|newest> <pg_major> <triple> "<full> <url> <sha256>"
func runPgext(args []string) error {
	usage := fmt.Errorf("usage: dzb pgext env|bundle-json <name> <version> <pg_major> | dzb pgext pgtree base|newest <pg_major> <triple>")
	if len(args) != 4 {
		return usage
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	switch args[0] {
	case "env", "bundle-json":
		major, err := strconv.Atoi(args[3])
		if err != nil {
			return fmt.Errorf("pg_major %q: %w", args[3], err)
		}
		if args[0] == "env" {
			out, err := cfg.pgextEnv(args[1], args[2], major)
			if err != nil {
				return err
			}
			fmt.Print(out)
			return nil
		}
		recipe := "recipes/pgext/build.sh"
		if sha := os.Getenv("GITHUB_SHA"); sha != "" {
			recipe += "@" + sha
		}
		out, err := cfg.bundleJSON(args[1], args[2], major, recipe)
		if err != nil {
			return err
		}
		fmt.Print(string(out))
		return nil
	case "pgtree":
		major, err := strconv.Atoi(args[2])
		if err != nil {
			return fmt.Errorf("pg_major %q: %w", args[2], err)
		}
		var full string
		switch args[1] {
		case "base":
			full, err = cfg.buildMinor(major)
		case "newest":
			full, err = cfg.newestMinor(major)
		default:
			return usage
		}
		if err != nil {
			return err
		}
		url, sum, err := pgtreeArtifact(full, args[3])
		if err != nil {
			return err
		}
		fmt.Printf("%s %s %s\n", full, url, sum)
		return nil
	}
	return usage
}

// bundleKeys are bundle.json's fields; every one must be present, no others.
var bundleKeys = []string{"name", "version", "pg_major", "preload", "settings", "env", "requires", "license", "source", "recipe"}

// readBundle parses and contract-checks a bundle.json: all ten fields present
// (lists and maps may be empty, never null), nothing else, and the name and
// version non-empty. The verify step runs it on what the archive SHIPS, so a
// recipe bug that drops a field fails before publish.
func readBundle(data []byte) (bundleManifest, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return bundleManifest{}, fmt.Errorf("bundle.json: %w", err)
	}
	for _, k := range bundleKeys {
		v, ok := raw[k]
		if !ok {
			return bundleManifest{}, fmt.Errorf("bundle.json: missing %q", k)
		}
		if string(v) == "null" {
			return bundleManifest{}, fmt.Errorf("bundle.json: %q is null", k)
		}
		delete(raw, k)
	}
	for k := range raw {
		return bundleManifest{}, fmt.Errorf("bundle.json: unexpected field %q", k)
	}
	var m bundleManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return bundleManifest{}, fmt.Errorf("bundle.json: %w", err)
	}
	if m.Name == "" || m.Version == "" || m.PGMajor == 0 || m.License == "" || m.Source == "" {
		return bundleManifest{}, fmt.Errorf("bundle.json: name, version, pg_major, license and source must be set")
	}
	return m, nil
}

// expandPlaceholders fills the module's placeholders the way the module will.
func expandPlaceholders(s, db, root string) string {
	return strings.NewReplacer("{db}", db, "{root}", root).Replace(s)
}

// bundleEnv renders a parsed bundle as shell assignments for verify.sh:
// the preload list, the requires list, postgresql.conf lines for its settings
// and `export` lines for its env, with {db} and {root} filled in.
func bundleEnv(m bundleManifest, db, root string) string {
	var conf, env []string
	for _, k := range sortedKeys(m.Settings) {
		v := strings.ReplaceAll(expandPlaceholders(m.Settings[k], db, root), "'", "''")
		conf = append(conf, fmt.Sprintf("%s = '%s'", k, v))
	}
	for _, k := range sortedKeys(m.Env) {
		env = append(env, fmt.Sprintf("export %s=%s", k, shellQuote(expandPlaceholders(m.Env[k], db, root))))
	}
	vars := [][2]string{
		{"BUNDLE_NAME", m.Name},
		{"BUNDLE_VERSION", m.Version},
		{"BUNDLE_PG_MAJOR", strconv.Itoa(m.PGMajor)},
		{"BUNDLE_PRELOAD", strings.Join(m.Preload, ",")},
		{"BUNDLE_REQUIRES", strings.Join(m.Requires, " ")},
		{"BUNDLE_CONF", strings.Join(conf, "\n")},
		{"BUNDLE_ENV", strings.Join(env, "\n")},
	}
	var b strings.Builder
	for _, kv := range vars {
		fmt.Fprintf(&b, "%s=%s\n", kv[0], shellQuote(kv[1]))
	}
	return b.String()
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// runBundleEnv is `dzb pgext-bundle <bundle.json> <db> <root>`.
func runBundleEnv(args []string) error {
	if len(args) != 3 {
		return fmt.Errorf("usage: dzb pgext-bundle <bundle.json> <db> <root>")
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	m, err := readBundle(data)
	if err != nil {
		return err
	}
	fmt.Print(bundleEnv(m, args[1], args[2]))
	return nil
}
