package main

import (
	"crypto/ed25519"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A catalog with bundle dependencies: postgis (bundled libraries), h3 (a
// provided name needing postgis), pgrouting (requires postgis) and
// vectorscale (requires vector).
const depsCatalog = `
triples:
  x86_64-unknown-linux-gnu:  ubuntu-22.04
  aarch64-apple-darwin:      macos-15
engines:
  postgres:
    archive_suffix: ".0"
    archive_name: postgresql
    versions: ["17.0", "18.0"]
extension_waves: [1, 2]
extensions:
  vector:
    wave: 1
    description: v
    homepage: https://example.com/v
    repo: https://example.com/v
    license: PostgreSQL
    pg: [17, 18]
    versions: ["0.8.7"]
  postgis:
    wave: 2
    description: p
    homepage: https://example.com/p
    repo: https://example.com/p
    license: GPL-2.0-or-later
    pg: [17, 18]
    versions: ["3.6.4"]
    provides: { postgis_tiger_geocoder: [postgis, fuzzystrmatch], postgis_raster: [postgis] }
    bundled:
      - { name: geos, version: "3.14.1", license: LGPL-2.1-or-later, source: "https://example.com/geos-3.14.1.tar.bz2", sha256: "3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716" }
      - { name: duck-db, version: "1.4.3", license: MIT, source: "https://github.com/duckdb/duckdb@d1dc88f9" }
  h3:
    wave: 2
    description: h
    homepage: https://example.com/h
    repo: https://example.com/h
    license: Apache-2.0
    pg: [17, 18]
    versions: ["4.2.3"]
    provides: { h3_postgis: [h3, postgis] }
  pgrouting:
    wave: 2
    description: r
    homepage: https://example.com/r
    repo: https://example.com/r
    ref: "v{v}"
    license: GPL-2.0-or-later
    pg: [17, 18]
    versions: ["3.8.0"]
    requires: [postgis]
  vectorscale:
    wave: 2
    description: s
    homepage: https://example.com/s
    repo: https://example.com/s
    license: PostgreSQL
    pg: [18]
    versions: ["0.9.1"]
    requires: [vector]
`

func TestBundleDepsAndStages(t *testing.T) {
	cfg := mustConfig(t, depsCatalog)
	cases := map[string]struct {
		deps  []string
		stage int
	}{
		"vector":      {nil, 1},
		"postgis":     {nil, 1}, // fuzzystrmatch is contrib; postgis_raster's postgis is itself
		"h3":          {[]string{"postgis"}, 2},
		"pgrouting":   {[]string{"postgis"}, 2},
		"vectorscale": {[]string{"vector"}, 2},
	}
	for n, c := range cases {
		if got := cfg.bundleDeps(n); !reflect.DeepEqual(got, c.deps) {
			t.Errorf("%s deps = %v, want %v", n, got, c.deps)
		}
		if got := cfg.buildStage(n); got != c.stage {
			t.Errorf("%s stage = %d, want %d", n, got, c.stage)
		}
	}
	out, err := cfg.pgextDeps("pgrouting", 18)
	if err != nil || out != "postgis 3.6.4\n" {
		t.Errorf("pgext deps pgrouting 18 = %q, %v", out, err)
	}
	if _, err := cfg.pgextDeps("nope", 18); err == nil {
		t.Error("unknown extension should fail")
	}
	items, err := cfg.planItems(cfg.engineGroup(true), func(string) (map[string]bool, error) { return nil, nil },
		func(string, string) bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range items {
		if want := cases[it.Ext].stage; it.Stage != want {
			t.Errorf("%s plan stage = %d, want %d", it.Engine, it.Stage, want)
		}
	}
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "recipes", "pgext"), 0o755); err != nil {
		t.Fatal(err)
	}
	if p := cfg.checkAddons(root); len(p) == 0 {
		t.Error("expected only missing-smoke problems, got none")
	} else {
		for _, s := range p {
			if !strings.Contains(s, "smoke.sql") {
				t.Errorf("unexpected problem: %s", s)
			}
		}
	}
}

func TestBundledEnvAndValidation(t *testing.T) {
	cfg := mustConfig(t, depsCatalog)
	env, err := cfg.pgextEnv("postgis", "3.6.4", 18)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"PGEXT_DEP_GEOS_VERSION='3.14.1'",
		"PGEXT_DEP_GEOS_SHA256='3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716'",
		"PGEXT_DEP_DUCK_DB_URL='https://github.com/duckdb/duckdb@d1dc88f9'",
		"PGEXT_BUNDLED='geos duck-db'",
	} {
		if !strings.Contains(env, want+"\n") {
			t.Errorf("env lacks %s:\n%s", want, env)
		}
	}
	if env, _ := cfg.pgextEnv("vector", "0.8.7", 18); !strings.Contains(env, "PGEXT_BUNDLED=''\n") {
		t.Errorf("vector env should have an empty PGEXT_BUNDLED:\n%s", env)
	}
	bad := []string{
		`{ name: Geos, version: "1", license: MIT, source: "https://x/y.tgz", sha256: "` + strings.Repeat("a", 64) + `" }`,
		`{ name: geos, version: "1", license: MIT, source: "https://x/y.tgz" }`,
		`{ name: geos, version: "1", license: MIT, source: "http://x/y.tgz", sha256: "` + strings.Repeat("a", 64) + `" }`,
		`{ name: geos, version: "1", source: "https://x@abc" }`,
	}
	for _, b := range bad {
		y := strings.Replace(depsCatalog, `      - { name: duck-db, version: "1.4.3", license: MIT, source: "https://github.com/duckdb/duckdb@d1dc88f9" }`, "      - "+b, 1)
		if _, err := parseConfig([]byte(y)); err == nil {
			t.Errorf("bundled %s should be rejected", b)
		}
	}
}

func TestAddonIndexSourcesAndBundled(t *testing.T) {
	priv := testKey(t)
	cfg := mustConfig(t, depsCatalog)
	dir := fullMirror(t, cfg, priv)
	idx, err := cfg.buildAddonIndex(mirrorSource{dir: dir, root: "/nonexistent"}, priv.Public().(ed25519.PublicKey))
	if err != nil {
		t.Fatal(err)
	}
	pr := idx.Addons["pgrouting"].Releases["3.8.0"]
	if !reflect.DeepEqual(pr.Sources, map[string]string{"17": "https://example.com/r@v3.8.0", "18": "https://example.com/r@v3.8.0"}) {
		t.Errorf("pgrouting sources = %v", pr.Sources)
	}
	pg := idx.Addons["postgis"]
	if len(pg.Bundled) != 2 || pg.Bundled[0].Name != "geos" || pg.Bundled[0].License != "LGPL-2.1-or-later" {
		t.Errorf("postgis bundled = %+v", pg.Bundled)
	}
	if _, err := renderAddonIndex(idx, priv); err != nil {
		t.Fatal(err)
	}
}

// A line that bundles different code: pg_duckdb 1.0.0 (14-17) and 1.1.1 (18).
func TestBundledPerVersion(t *testing.T) {
	y := strings.Replace(depsCatalog, "extensions:\n", `extensions:
  pg_duckdb:
    wave: 2
    description: d
    homepage: https://example.com/d
    repo: https://example.com/d
    license: MIT
    pg: [18]
    versions: ["1.1.1"]
    lines:
      17: { versions: ["1.0.0"] }
    bundled:
      - { name: duckdb, version: "1.4.3", license: MIT, source: "https://example.com/duckdb@new", versions: ["1.1.1"] }
      - { name: curl, version: "8.23.0", license: curl, source: "https://example.com/curl@x", versions: ["1.1.1"] }
      - { name: duckdb, version: "1.3.2", license: MIT, source: "https://example.com/duckdb@old", versions: ["1.0.0"] }
`, 1)
	cfg := mustConfig(t, y)
	old, err := cfg.pgextEnv("pg_duckdb", "1.0.0", 17)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(old, "PGEXT_DEP_DUCKDB_URL='https://example.com/duckdb@old'\n") || strings.Contains(old, "CURL") ||
		!strings.Contains(old, "PGEXT_BUNDLED='duckdb'\n") {
		t.Errorf("1.0.0 env:\n%s", old)
	}
	cur, _ := cfg.pgextEnv("pg_duckdb", "1.1.1", 18)
	if !strings.Contains(cur, "PGEXT_DEP_DUCKDB_URL='https://example.com/duckdb@new'\n") || !strings.Contains(cur, "PGEXT_BUNDLED='duckdb curl'\n") {
		t.Errorf("1.1.1 env:\n%s", cur)
	}
	// The same name twice for one version, or a version that is not catalogued.
	for _, bad := range []string{
		strings.Replace(y, `source: "https://example.com/duckdb@old", versions: ["1.0.0"]`, `source: "https://example.com/duckdb@old"`, 1),
		strings.Replace(y, `source: "https://example.com/duckdb@old", versions: ["1.0.0"]`, `source: "https://example.com/duckdb@old", versions: ["9.9"]`, 1),
	} {
		if _, err := parseConfig([]byte(bad)); err == nil {
			t.Error("expected a bundled validation error")
		}
	}
}
