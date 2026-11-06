package main

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

const testCatalog = `
triples:
  x86_64-unknown-linux-gnu:  ubuntu-22.04
  aarch64-apple-darwin:      macos-14
engines:
  postgres:
    ref: "REL_{v_}"
    archive_suffix: ".0"
    archive_name: postgresql
    versions: ["16.0", "16.9", "16.14", "17.1", "17.0", "17.11", "18.0"]
  valkey:
    versions: ["9.0.0"]
extensions:
  vector:
    repo: https://github.com/pgvector/pgvector
    ref: "v{v}"
    license: PostgreSQL
    pg: [16, 17]
    versions: ["0.8.6", "0.8.7"]
  pg_cron:
    repo: https://github.com/citusdata/pg_cron
    ref: "v{v}"
    license: PostgreSQL
    pg: [17]
    versions: ["1.6.8"]
    preload: [pg_cron]
    settings: { cron.database_name: "{db}" }
  pg_hint_plan:
    repo: https://github.com/ossc-db/pg_hint_plan
    ref: "REL{pg}_{v_}"
    license: BSD-3-Clause
    lines:
      16: { versions: ["1.6.3"] }
      17: { versions: ["1.7.1", "1.7.2"] }
  pgaudit:
    repo: https://github.com/pgaudit/pgaudit
    license: PostgreSQL
    pg: [18]
    versions: ["18.0"]
    lines:
      17: { versions: ["17.1"], ref: "REL_17_{v}" }
`

func mustConfig(t *testing.T, y string) *config {
	t.Helper()
	cfg, err := parseConfig([]byte(y))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestExpandExtensions(t *testing.T) {
	cfg := mustConfig(t, testCatalog)
	want := []string{
		"pgext-pg_cron-pg17",
		"pgext-pg_hint_plan-pg16", "pgext-pg_hint_plan-pg17",
		"pgext-pgaudit-pg17", "pgext-pgaudit-pg18",
		"pgext-vector-pg16", "pgext-vector-pg17",
	}
	if got := cfg.engineGroup(true); !reflect.DeepEqual(got, want) {
		t.Fatalf("pgext engines = %v, want %v", got, want)
	}
	if got := cfg.engineGroup(false); !reflect.DeepEqual(got, []string{"postgres", "valkey"}) {
		t.Fatalf("base engines = %v", got)
	}
	cases := []struct {
		engine   string
		versions []string
		ref      string // for the last version
	}{
		{"pgext-vector-pg17", []string{"0.8.6", "0.8.7"}, "v0.8.7"},
		// Per-major lines: {pg} and {v_} both expand.
		{"pgext-pg_hint_plan-pg16", []string{"1.6.3"}, "REL16_1_6_3"},
		{"pgext-pg_hint_plan-pg17", []string{"1.7.1", "1.7.2"}, "REL17_1_7_2"},
		// A line's own ref overrides; a major in pg without a line uses the top level.
		{"pgext-pgaudit-pg17", []string{"17.1"}, "REL_17_17.1"},
		{"pgext-pgaudit-pg18", []string{"18.0"}, "18.0"},
	}
	for _, c := range cases {
		spec := cfg.Engines[c.engine]
		if !reflect.DeepEqual(spec.Versions, c.versions) {
			t.Errorf("%s versions = %v, want %v", c.engine, spec.Versions, c.versions)
		}
		if got := spec.ref(c.versions[len(c.versions)-1]); got != c.ref {
			t.Errorf("%s ref = %q, want %q", c.engine, got, c.ref)
		}
		if spec.MajorParts != 2 {
			t.Errorf("%s major_parts = %d, want 2 (the contract's ResolveMajor(\"0.8\"))", c.engine, spec.MajorParts)
		}
		if spec.ArchiveName != "" || spec.ArchiveSuffix != "" {
			t.Errorf("%s: archives must be named pgext-<name>-pg<major>-<version>", c.engine)
		}
	}
}

func TestExpandExtensionsRejects(t *testing.T) {
	base := "triples: {aarch64-apple-darwin: macos-14}\nengines:\n  postgres: {versions: [\"17.0\"]}\n"
	cases := map[string]string{
		"no repo":         "extensions:\n  x: {license: MIT, pg: [17], versions: [\"1.0\"]}\n",
		"no license":      "extensions:\n  x: {repo: r, pg: [17], versions: [\"1.0\"]}\n",
		"no majors":       "extensions:\n  x: {repo: r, license: MIT, versions: [\"1.0\"]}\n",
		"no versions":     "extensions:\n  x: {repo: r, license: MIT, pg: [17]}\n",
		"unknown major":   "extensions:\n  x: {repo: r, license: MIT, pg: [12], versions: [\"1.0\"]}\n",
		"bad build":       "extensions:\n  x: {repo: r, license: MIT, pg: [17], versions: [\"1.0\"], build: cmake}\n",
		"empty line":      "extensions:\n  x: {repo: r, license: MIT, lines: {17: {versions: []}}}\n",
		"reserved engine": "  pgext-x-pg17: {versions: [\"1.0\"]}\n",
	}
	for name, extra := range cases {
		if _, err := parseConfig([]byte(base + extra)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestBuildAndNewestMinor(t *testing.T) {
	cfg := mustConfig(t, testCatalog)
	// Oldest by VERSION, not by list position (17.1 is listed before 17.0).
	if got, _ := cfg.buildMinor(17); got != "17.0.0" {
		t.Errorf("buildMinor(17) = %q, want 17.0.0", got)
	}
	if got, _ := cfg.newestMinor(16); got != "16.14.0" {
		t.Errorf("newestMinor(16) = %q, want 16.14.0 (numeric, not lexical)", got)
	}
	if _, err := cfg.buildMinor(14); err == nil {
		t.Error("buildMinor(14) should fail: no postgres 14 catalogued")
	}
}

func TestPlanItemsPgext(t *testing.T) {
	cfg := mustConfig(t, testCatalog)
	published := func(engine string) (map[string]bool, error) {
		if engine == "pgext-vector-pg17" {
			return map[string]bool{key(engine, "0.8.6", "aarch64-apple-darwin"): true}, nil
		}
		return map[string]bool{}, nil
	}
	none := func(string, string) bool { return false }
	items, err := cfg.planItems([]string{"pgext-vector-pg17", "valkey"}, published, none)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, it := range items {
		got = append(got, it.Engine+" "+it.Version+" "+it.Triple+" "+it.Ext)
		if it.Engine == "pgext-vector-pg17" && (it.Ext != "vector" || it.PGMajor != 17) {
			t.Errorf("pgext item missing ext/pg_major: %+v", it)
		}
		if it.Engine == "valkey" && (it.Ext != "" || it.PGMajor != 0) {
			t.Errorf("base engine item has ext fields: %+v", it)
		}
	}
	want := []string{
		"pgext-vector-pg17 0.8.6 x86_64-unknown-linux-gnu vector", // the darwin one is published
		"pgext-vector-pg17 0.8.7 aarch64-apple-darwin vector",
		"pgext-vector-pg17 0.8.7 x86_64-unknown-linux-gnu vector",
		"valkey 9.0.0 aarch64-apple-darwin ",
		"valkey 9.0.0 x86_64-unknown-linux-gnu ",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("plan =\n%v\nwant\n%v", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// The matrix JSON omits ext/pg_major for base engines (build-engine.yml
	// never sees them) and carries them for bundles.
	b, _ := json.Marshal(items[0])
	if !strings.Contains(string(b), `"ext":"vector","pg_major":17`) {
		t.Errorf("pgext matrix item JSON = %s", b)
	}
	b, _ = json.Marshal(items[3])
	if strings.Contains(string(b), "ext") || strings.Contains(string(b), "pg_major") {
		t.Errorf("base matrix item JSON = %s", b)
	}
}

func TestManifestPgext(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{
		"pgext-vector-pg17-0.8.6-aarch64-apple-darwin.tar.gz",
		"pgext-vector-pg17-0.8.7-aarch64-apple-darwin.tar.gz",
		"pgext-pg_hint_plan-pg17-1.7.2-x86_64-unknown-linux-gnu.tar.gz",
	} {
		if err := os.WriteFile(dir+"/"+n, []byte(n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := mustConfig(t, testCatalog)
	prefixes, toEngine := cfg.archivePrefixes()
	re := buildArchiveNameRe(prefixes)
	m := re.FindStringSubmatch("pgext-pg_hint_plan-pg17-1.7.2-x86_64-unknown-linux-gnu.tar.gz")
	if m == nil || toEngine[m[1]] != "pgext-pg_hint_plan-pg17" || m[2] != "1.7.2" {
		t.Fatalf("archive name parse = %v", m)
	}
	// pg16's archive must not be mistaken for pg17's or vice versa.
	m = re.FindStringSubmatch("pgext-vector-pg16-0.8.7-aarch64-apple-darwin.tar.gz")
	if m == nil || m[1] != "pgext-vector-pg16" {
		t.Fatalf("pg16 archive parsed as %v", m)
	}
	if got := majorKey("0.8.7", cfg.Engines["pgext-vector-pg17"].MajorParts); got != "0.8" {
		t.Errorf("vector major key = %q, want 0.8", got)
	}
}

func TestBundleJSON(t *testing.T) {
	cfg := mustConfig(t, testCatalog)
	b, err := cfg.bundleJSON("pg_cron", "1.6.8", 17, "recipes/pgext/build.sh")
	if err != nil {
		t.Fatal(err)
	}
	// Field order and presence are the contract; empty lists/maps, never null.
	want := `{
  "name": "pg_cron",
  "version": "1.6.8",
  "pg_major": 17,
  "preload": [
    "pg_cron"
  ],
  "settings": {
    "cron.database_name": "{db}"
  },
  "env": {},
  "requires": [],
  "license": "PostgreSQL",
  "source": "https://github.com/citusdata/pg_cron@v1.6.8",
  "recipe": "recipes/pgext/build.sh"
}
`
	if string(b) != want {
		t.Errorf("bundle.json =\n%s\nwant\n%s", b, want)
	}
	if _, err := readBundle(b); err != nil {
		t.Errorf("our own bundle.json fails the contract check: %v", err)
	}
	b, err = cfg.bundleJSON("pg_hint_plan", "1.7.2", 17, "r")
	if err != nil || !strings.Contains(string(b), `"source": "https://github.com/ossc-db/pg_hint_plan@REL17_1_7_2"`) {
		t.Errorf("hint_plan bundle.json source: %s %v", b, err)
	}
	if _, err := cfg.bundleJSON("vector", "9.9.9", 17, "r"); err == nil {
		t.Error("an uncatalogued version must be refused")
	}
	if _, err := cfg.bundleJSON("pg_cron", "1.6.8", 16, "r"); err == nil {
		t.Error("an uncatalogued major must be refused")
	}
}

func TestReadBundleContract(t *testing.T) {
	good := `{"name":"x","version":"1","pg_major":17,"preload":[],"settings":{},"env":{},"requires":[],"license":"MIT","source":"r@v1","recipe":"r"}`
	if _, err := readBundle([]byte(good)); err != nil {
		t.Fatalf("good bundle rejected: %v", err)
	}
	bad := map[string]string{
		"missing env": strings.Replace(good, `"env":{},`, "", 1),
		"null list":   strings.Replace(good, `"requires":[]`, `"requires":null`, 1),
		"extra field": strings.Replace(good, `"recipe":"r"`, `"recipe":"r","extra":1`, 1),
		"no name":     strings.Replace(good, `"name":"x"`, `"name":""`, 1),
		"not json":    "{",
	}
	for name, b := range bad {
		if _, err := readBundle([]byte(b)); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

func TestBundleEnv(t *testing.T) {
	m := bundleManifest{
		Name: "pg_cron", Version: "1.6.8", PGMajor: 17,
		Preload:  []string{"pg_cron", "pgaudit"},
		Settings: map[string]string{"cron.database_name": "{db}", "x.path": "{root}/it's"},
		Env:      map[string]string{"PROJ_DATA": "{root}/share/proj"},
		Requires: []string{"a", "b"},
	}
	got := bundleEnv(m, "app", "/r")
	for _, want := range []string{
		"BUNDLE_PRELOAD='pg_cron,pgaudit'",
		"BUNDLE_REQUIRES='a b'",
		// conf values are SQL-quoted ('' for '), then shell-quoted.
		`BUNDLE_CONF='cron.database_name = '\''app'\''` + "\n" + `x.path = '\''/r/it'\'''\''s'\'''`,
		`BUNDLE_ENV='export PROJ_DATA='\''/r/share/proj'\'''`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("bundleEnv missing %s\n--- got:\n%s", want, got)
		}
	}
}

func TestVerifyItems(t *testing.T) {
	cfg := mustConfig(t, testCatalog)
	all, err := cfg.verifyItems("")
	if err != nil {
		t.Fatal(err)
	}
	// 2 base engines x 2 triples, plus bundles grouped per (major, triple):
	// majors 16, 17, 18 x 2 triples.
	if len(all) != 2*2+3*2 {
		t.Errorf("all = %d items, want 10: %+v", len(all), all)
	}
	var pg17 *verifyItem
	for i := range all {
		if all[i].Name == "pgext-pg17" && all[i].Triple == "aarch64-apple-darwin" {
			pg17 = &all[i]
		}
	}
	want := "pgext-pg_cron-pg17 pgext-pg_hint_plan-pg17 pgext-pgaudit-pg17 pgext-vector-pg17"
	if pg17 == nil || pg17.Engines != want {
		t.Errorf("pgext-pg17 group = %+v, want engines %q", pg17, want)
	}
	some, err := cfg.verifyItems("valkey,--pgext valkey")
	if err != nil || len(some) != 1*2+3*2 {
		t.Errorf("valkey,--pgext = %d items (%v), want 8", len(some), err)
	}
	if _, err := cfg.verifyItems("nope"); err == nil {
		t.Error("unknown engine should fail")
	}
}

// The real catalog must parse and expand; this is the check that a
// versions.yaml edit didn't break plan/manifest for every engine.
func TestRealCatalog(t *testing.T) {
	data, err := os.ReadFile("../../versions.yaml")
	if err != nil {
		t.Skip(err)
	}
	cfg, err := parseConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.engineGroup(true)) == 0 {
		t.Fatal("no extension bundles expanded from versions.yaml")
	}
	for _, e := range cfg.engineGroup(true) {
		ext := cfg.pgext[e]
		if _, err := cfg.buildMinor(ext.PGMajor); err != nil {
			t.Errorf("%s: %v", e, err)
		}
		for _, v := range cfg.Engines[e].Versions {
			if _, err := cfg.bundleJSON(ext.Name, v, ext.PGMajor, "r"); err != nil {
				t.Errorf("%s %s: %v", e, v, err)
			}
		}
	}
}
