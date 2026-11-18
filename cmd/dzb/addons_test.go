package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// testKey is a throwaway signing key, installed as DZB_SIGNING_KEY for the
// test. Never the real one.
func testKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(signingKeyEnv, base64.StdEncoding.EncodeToString(der))
	got, err := signingKey()
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestSigningKeyErrors(t *testing.T) {
	t.Setenv(signingKeyEnv, "")
	if _, err := signingKey(); err == nil {
		t.Error("unset key should fail")
	}
	t.Setenv(signingKeyEnv, "not base64!")
	if _, err := signingKey(); err == nil || strings.Contains(err.Error(), "not base64!") {
		t.Errorf("bad key should fail without echoing it: %v", err)
	}
}

func TestCanonicalJSON(t *testing.T) {
	doc := map[string]any{
		"signature": "dropped",
		"b":         []any{"x<y>&z", 2, true},
		"a":         map[string]any{"z": "—", "m": map[string]any{}},
	}
	got, err := canonicalJSON(doc)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"a":{"m":{},"z":"—"},"b":["x<y>&z",2,true]}`
	if string(got) != want {
		t.Errorf("canonical = %s\nwant        %s", got, want)
	}
	for name, bad := range map[string]any{
		"float":     1.5,
		"null":      nil,
		"control":   "a\tb",
		"separator": "a b",
	} {
		if _, err := canonicalJSON(map[string]any{"k": bad}); err == nil {
			t.Errorf("%s: should be refused", name)
		}
	}
}

func TestSignManifestRoundTrip(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	man := manifest{Engines: map[string]*engineManifest{
		"temporal": {
			Versions: map[string]string{"1.10": "1.10.0", "1": "1.10.0"},
			Artifacts: map[string]map[string]artifact{
				"1.10.0": {
					"aarch64-apple-darwin":   {URL: "https://x/temporal-1.10.0-aarch64-apple-darwin.tar.gz", SHA256: "AB12"},
					"x86_64-pc-windows-msvc": {URL: "https://x/temporal-1.10.0-x86_64-pc-windows-msvc.tar.gz", SHA256: "cd34"},
				},
			},
		},
	}}
	signed, err := signManifest(man, priv)
	if err != nil {
		t.Fatal(err)
	}
	n, err := verifyDocument(signed, pub)
	if err != nil || n != 2 {
		t.Fatalf("verify = %d, %v\n%s", n, err, signed)
	}
	// Re-signing what was read back gives the same bytes (ed25519 is
	// deterministic), so republishing an unchanged index changes nothing.
	var back manifest
	if err := yaml.Unmarshal(signed, &back); err != nil {
		t.Fatal(err)
	}
	again, err := signManifest(back, priv)
	if err != nil || string(again) != string(signed) {
		t.Errorf("re-signing changed the index (%v):\n%s\n---\n%s", err, signed, again)
	}
	// The doze-sdk reader still parses it: the "1.10" key stays a string.
	if back.Engines["temporal"].Versions["1.10"] != "1.10.0" {
		t.Errorf("versions map lost its string keys: %v", back.Engines["temporal"].Versions)
	}

	tamper := map[string]func(string) string{
		"url": func(s string) string {
			return strings.Replace(s, "https://x/temporal-1.10.0-aarch64", "https://evil/temporal-1.10.0-aarch64", 1)
		},
		"new field": func(s string) string { return s + "extra: 1\n" },
		"sha":       func(s string) string { return strings.Replace(s, "sha256: cd34", "sha256: cd35", 1) },
	}
	for name, f := range tamper {
		if _, err := verifyDocument([]byte(f(string(signed))), pub); err == nil {
			t.Errorf("tampered %s: verified anyway", name)
		}
	}
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := verifyDocument(signed, other.Public().(ed25519.PublicKey)); err == nil {
		t.Error("verified with another key")
	}
	if _, err := signDocument(signed, priv); err == nil {
		t.Error("signing a signed document should refuse")
	}
}

// writeMirror writes a signed (or unsigned, priv nil) bundle mirror index
// into dir/<engine>/index.yaml for the given (version -> triples).
func writeMirror(t *testing.T, dir, engine string, arts map[string][]string, priv ed25519.PrivateKey) {
	t.Helper()
	em := &engineManifest{Versions: map[string]string{}, Artifacts: map[string]map[string]artifact{}}
	for v, triples := range arts {
		em.Artifacts[v] = map[string]artifact{}
		for _, tr := range triples {
			name := fmt.Sprintf("%s-%s-%s.tar.gz", engine, v, tr)
			em.Artifacts[v][tr] = artifact{URL: "https://mirror/" + engine + "/" + name, SHA256: fmt.Sprintf("%064x", len(name)*7+len(v))}
		}
		em.Versions[majorKey(v, 2)] = v
	}
	man := manifest{Engines: map[string]*engineManifest{engine: em}}
	var body []byte
	var err error
	if priv != nil {
		body, err = signManifest(man, priv)
	} else {
		body, err = yaml.Marshal(man)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, engine), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, engine, "index.yaml"), body, 0o644); err != nil {
		t.Fatal(err)
	}
}

var bothTriples = []string{"aarch64-apple-darwin", "x86_64-unknown-linux-gnu"}

// fullMirror publishes every built (extension, major, version, triple) of
// testCatalog.
func fullMirror(t *testing.T, cfg *config, priv ed25519.PrivateKey) string {
	dir := t.TempDir()
	for _, e := range cfg.engineGroup(true) {
		arts := map[string][]string{}
		for _, v := range cfg.Engines[e].Versions {
			arts[v] = bothTriples
		}
		writeMirror(t, dir, e, arts, priv)
	}
	return dir
}

func TestBuildAddonIndex(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	cfg := mustConfig(t, testCatalog)
	dir := fullMirror(t, cfg, priv)
	idx, err := cfg.buildAddonIndex(mirrorSource{dir: dir, root: "/nonexistent"}, pub)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := idx.Addons["postgis"]; ok {
		t.Error("wave 2 must stay out of the index")
	}
	if got := len(idx.Addons); got != 4 {
		t.Errorf("addons = %d, want 4", got)
	}
	v := idx.Addons["vector"]
	if v.Line != "0.8" || v.Lines != nil || !reflect.DeepEqual(v.Majors, []string{"16", "17"}) ||
		!reflect.DeepEqual(v.Aliases, []string{"pgvector"}) || v.Channels["stable"] != "0.8.7" {
		t.Errorf("vector = %+v", v)
	}
	if r := v.Releases["0.8.6"]; !reflect.DeepEqual(r.Engines, []string{"16", "17"}) ||
		len(r.Artifacts["16"]) != 2 || r.Artifacts["17"]["aarch64-apple-darwin"].URL == "" {
		t.Errorf("vector 0.8.6 = %+v", r)
	}
	// Lines: one series per major, no default line (as the Go catalog had it).
	hp := idx.Addons["pg_hint_plan"]
	if hp.Line != "" || !reflect.DeepEqual(hp.Lines, map[string]string{"16": "1.6", "17": "1.7"}) {
		t.Errorf("pg_hint_plan line %q lines %v", hp.Line, hp.Lines)
	}
	if r := hp.Releases["1.7.1"]; !reflect.DeepEqual(r.Engines, []string{"17"}) {
		t.Errorf("pg_hint_plan 1.7.1 engines = %v", r.Engines)
	}
	// A top-level line plus one major with its own.
	pa := idx.Addons["pgaudit"]
	if pa.Line != "18.0" || !reflect.DeepEqual(pa.Lines, map[string]string{"17": "17.1"}) || !reflect.DeepEqual(pa.Majors, []string{"17", "18"}) {
		t.Errorf("pgaudit line %q lines %v majors %v", pa.Line, pa.Lines, pa.Majors)
	}
	if pc := idx.Addons["pg_cron"]; pc.Settings["cron.database_name"] != "{db}" || !reflect.DeepEqual(pc.Preload, []string{"pg_cron"}) {
		t.Errorf("pg_cron = %+v", pc)
	}

	out, err := renderAddonIndex(idx, priv)
	if err != nil {
		t.Fatal(err)
	}
	n, err := verifyDocument(out, pub)
	// vector 2 versions x 2 majors, pg_cron 1x1, hint_plan 3 (16: 1, 17: 2),
	// pgaudit 17 + 18: (4+1+3+2) x 2 triples.
	if err != nil || n != 20 {
		t.Fatalf("verify = %d, %v\n%s", n, err, out)
	}
	if !strings.HasPrefix(string(out), "schema: 1\nindex: postgres-extensions\nengine: postgres\nnoun: extension\n") {
		t.Errorf("header:\n%s", out[:120])
	}
	// The release keys and major keys must read back as strings.
	var doc map[string]any
	if err := yaml.Unmarshal(out, &doc); err != nil {
		t.Fatal(err)
	}
	vec := doc["addons"].(map[string]any)["vector"].(map[string]any)
	if _, ok := vec["releases"].(map[string]any)["0.8.7"]; !ok {
		t.Errorf("release key 0.8.7 did not read back as a string: %v", vec["releases"])
	}
	if _, ok := vec["majors"].([]any)[0].(string); !ok {
		t.Error("majors must be strings")
	}
}

func TestBuildAddonIndexMismatch(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	cfg := mustConfig(t, testCatalog)
	cases := map[string]struct {
		mutate func(dir string)
		want   string
	}{
		"missing triple": {
			func(dir string) {
				writeMirror(t, dir, "pgext-vector-pg17", map[string][]string{"0.8.6": bothTriples, "0.8.7": {"aarch64-apple-darwin"}}, priv)
			},
			"vector 0.8.7 for Postgres 17: no x86_64-unknown-linux-gnu artifact",
		},
		"never built": {
			func(dir string) { os.RemoveAll(filepath.Join(dir, "pgext-pg_cron-pg17")) },
			"pg_cron: no published index",
		},
		"uncatalogued version": {
			func(dir string) {
				writeMirror(t, dir, "pgext-pg_cron-pg17", map[string][]string{"1.6.8": bothTriples, "1.6.9": bothTriples}, priv)
			},
			"has version 1.6.9, which versions.yaml does not catalogue",
		},
		"uncatalogued triple": {
			func(dir string) {
				writeMirror(t, dir, "pgext-pg_cron-pg17", map[string][]string{"1.6.8": append([]string{"x86_64-pc-windows-msvc"}, bothTriples...)}, priv)
			},
			"artifact for x86_64-pc-windows-msvc, a triple the catalog does not build",
		},
		"unsigned mirror": {
			func(dir string) {
				writeMirror(t, dir, "pgext-pg_cron-pg17", map[string][]string{"1.6.8": bothTriples}, nil)
			},
			"index is unsigned",
		},
	}
	for name, c := range cases {
		dir := fullMirror(t, cfg, priv)
		c.mutate(dir)
		_, err := cfg.buildAddonIndex(mirrorSource{dir: dir, root: "/nonexistent"}, pub)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", name, err, c.want)
		}
	}
	// Unsigned mode (local preview) takes an unsigned mirror.
	dir := fullMirror(t, cfg, nil)
	if _, err := cfg.buildAddonIndex(mirrorSource{dir: dir, root: "/nonexistent"}, nil); err != nil {
		t.Errorf("unsigned preview: %v", err)
	}
}

func TestCheckAddons(t *testing.T) {
	root := t.TempDir()
	for _, n := range []string{"vector", "pg_cron", "pg_hint_plan", "pgaudit"} {
		if err := os.MkdirAll(filepath.Join(root, "recipes", "pgext", n), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "recipes", "pgext", n, "smoke.sql"), []byte("SELECT 1;"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := mustConfig(t, testCatalog)
	if p := cfg.checkAddons(root); len(p) != 0 {
		t.Fatalf("clean catalog: %v", p)
	}

	os.Remove(filepath.Join(root, "recipes", "pgext", "pgaudit", "smoke.sql"))
	os.MkdirAll(filepath.Join(root, "recipes", "pgext", "pg_stray"), 0o755)
	p := strings.Join(cfg.checkAddons(root), "\n")
	for _, want := range []string{"pgaudit is in the built set (wave 1) but has no recipes/pgext/pgaudit/smoke.sql", "recipes/pgext/pg_stray has no catalog entry"} {
		if !strings.Contains(p, want) {
			t.Errorf("missing %q in:\n%s", want, p)
		}
	}

	// Names, aliases and provided names are one namespace; a built entry
	// can't require an unbuilt one, or one missing for its majors.
	y := strings.Replace(testCatalog, "aliases: [pgvector]", "aliases: [pgvector, pg_cron]", 1)
	y = strings.Replace(y, "    preload: [pg_cron]\n", "    preload: [pg_cron]\n    requires: [postgis]\n", 1)
	y = strings.Replace(y, "    aliases: [pgvector, pg_cron]\n", "    aliases: [pgvector, pg_cron]\n    requires: [pg_cron]\n", 1)
	cfg = mustConfig(t, y)
	p = strings.Join(cfg.checkAddons(root), "\n")
	for _, want := range []string{
		`"pg_cron" is claimed twice`,
		"pg_cron requires postgis, which is wave 2 and not built",
		"vector is built for Postgres 16 but requires pg_cron, which is not",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("missing %q in:\n%s", want, p)
		}
	}
}

// The real catalog and recipes must pass the check: a catalog entry with no
// recipe, or a recipe with no entry, fails here before any build runs.
func TestRealCatalogAddons(t *testing.T) {
	data, err := os.ReadFile("../../versions.yaml")
	if err != nil {
		t.Skip(err)
	}
	cfg, err := parseConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	if p := cfg.checkAddons("../.."); len(p) != 0 {
		t.Fatalf("versions.yaml extensions:\n  %s", strings.Join(p, "\n  "))
	}
	built := cfg.builtExtensions()
	if len(built) != 16 {
		t.Errorf("built set = %v, want wave 1's 10 and wave 2's 6", built)
	}
	for _, n := range []string{"postgis", "h3", "pgrouting", "pg_duckdb", "vectorscale", "age"} {
		if !contains(built, n) {
			t.Errorf("%s is wave 2 and must be built", n)
		}
	}
	// Left out on purpose (the owner's licence call): not even catalogued.
	for _, n := range []string{"timescaledb", "pg_search"} {
		if _, ok := cfg.Extensions[n]; ok {
			t.Errorf("%s must not be in the catalog", n)
		}
	}
	// What the Go module catalog compiled in, restored.
	cron := addonMeta(cfg.Extensions["pg_cron"])
	if cron.Settings["cron.use_background_workers"] != "on" || cron.Line != "1.6" {
		t.Errorf("pg_cron = %+v", cron)
	}
	audit := addonMeta(cfg.Extensions["pgaudit"])
	want := map[string]string{"14": "1.6", "15": "1.7", "16": "16.1", "17": "17.1", "18": "18.0"}
	if audit.Line != "" || !reflect.DeepEqual(audit.Lines, want) {
		t.Errorf("pgaudit line %q lines %v", audit.Line, audit.Lines)
	}
	if pm := addonMeta(cfg.Extensions["pg_partman"]); !reflect.DeepEqual(pm.MayPreload, []string{"pg_partman_bgw"}) {
		t.Errorf("pg_partman may_preload = %v", pm.MayPreload)
	}
}
