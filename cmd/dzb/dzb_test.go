package main

import (
	"reflect"
	"testing"
)

func TestVersionLess(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"16.9", "16.14", true}, // numeric, not lexicographic
		{"16.14", "16.9", false},
		{"16.14", "16.14", false}, // equal
		{"2.9.0", "2.16.0", true},
		{"8.1.8", "9.0.0", true},
		{"1.1", "1.1.0", true}, // shorter is less when the extra segment exists
		// The documentdb shapes: dash segments must compare numerically, not be
		// swallowed by a dot-only split (which read 112-0 == 112-1 and left the
		// majors map to map-iteration order).
		{"0.112-0", "0.112-1", true},
		{"0.112-1", "0.112-0", false},
		{"0.112-0", "0.112-0", false},
		{"0.102-0", "0.112-0", true},
	}
	for _, c := range cases {
		if got := versionLess(c.a, c.b); got != c.want {
			t.Errorf("versionLess(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestMajorKey(t *testing.T) {
	cases := []struct {
		full  string
		parts int
		want  string
	}{
		{"16.14.0", 1, "16"},
		{"16.14.0", 0, "16"}, // parts < 1 clamps to 1
		{"1.1.0", 2, "1.1"},  // temporal's two-part major
		{"11.4.5", 2, "11.4"},
		{"0.112-0", 1, "0"}, // documentdb: the dash stays inside the second part
		{"9.1.0", 3, "9.1.0"},
		{"9", 2, "9"}, // fewer parts than asked for
	}
	for _, c := range cases {
		if got := majorKey(c.full, c.parts); got != c.want {
			t.Errorf("majorKey(%q, %d) = %q, want %q", c.full, c.parts, got, c.want)
		}
	}
}

func TestRefAndArchiveVersion(t *testing.T) {
	cases := []struct {
		spec    engineSpec
		v       string
		wantRef string
		wantArc string
	}{
		{engineSpec{Ref: "REL_{v_}", ArchiveSuffix: ".0"}, "16.14", "REL_16_14", "16.14.0"},
		{engineSpec{Ref: "v{v}"}, "2.16.0", "v2.16.0", "2.16.0"},
		{engineSpec{Ref: "mariadb-{v}"}, "11.4.5", "mariadb-11.4.5", "11.4.5"},
		{engineSpec{}, "9.1.0", "9.1.0", "9.1.0"}, // default template "{v}"
		{engineSpec{Ref: "v{v}"}, "0.112-0", "v0.112-0", "0.112-0"},
	}
	for _, c := range cases {
		if got := c.spec.ref(c.v); got != c.wantRef {
			t.Errorf("ref(%q) with %q = %q, want %q", c.v, c.spec.Ref, got, c.wantRef)
		}
		if got := c.spec.archiveVersion(c.v); got != c.wantArc {
			t.Errorf("archiveVersion(%q) = %q, want %q", c.v, got, c.wantArc)
		}
	}
}

func TestRebuildSet(t *testing.T) {
	t.Setenv("DZB_REBUILD", "16.14.0, 2.16.0:aarch64-apple-darwin")
	forced := rebuildSet()
	if !forced("16.14.0", "x86_64-unknown-linux-gnu") {
		t.Error("bare full should force every triple")
	}
	if !forced("2.16.0", "aarch64-apple-darwin") {
		t.Error("full:triple should force that triple")
	}
	if forced("2.16.0", "x86_64-unknown-linux-gnu") {
		t.Error("full:triple must not force other triples")
	}
	t.Setenv("DZB_REBUILD", "")
	if rebuildSet()("16.14.0", "x86_64-unknown-linux-gnu") {
		t.Error("empty DZB_REBUILD should force nothing")
	}
}

func TestArchiveNameRe(t *testing.T) {
	re := buildArchiveNameRe([]string{"postgresql", "kvrocks", "documentdb"})
	cases := []struct {
		name string
		want []string // prefix, version, triple; nil = no match
	}{
		{"postgresql-16.14.0-aarch64-apple-darwin.tar.gz", []string{"postgresql", "16.14.0", "aarch64-apple-darwin"}},
		// documentdb's version itself contains a dash — the triple boundary must
		// still be found (the reason the version is matched loosely).
		{"documentdb-0.112-0-x86_64-unknown-linux-gnu.tar.gz", []string{"documentdb", "0.112-0", "x86_64-unknown-linux-gnu"}},
		{"kvrocks-2.16.0-aarch64-unknown-linux-gnu.tar.gz", []string{"kvrocks", "2.16.0", "aarch64-unknown-linux-gnu"}},
		{"valkey-9.1.0-aarch64-apple-darwin.tar.gz", nil},    // prefix not registered
		{"postgresql-16.14.0-aarch64-apple-darwin.zip", nil}, // wrong extension
		{"index.yaml", nil},
	}
	for _, c := range cases {
		m := re.FindStringSubmatch(c.name)
		if c.want == nil {
			if m != nil {
				t.Errorf("%q should not match, got %v", c.name, m)
			}
			continue
		}
		if m == nil {
			t.Errorf("%q should match", c.name)
			continue
		}
		if !reflect.DeepEqual(m[1:4], c.want) {
			t.Errorf("%q parsed as %v, want %v", c.name, m[1:4], c.want)
		}
	}
}

// temporal keys by line ("1.10") for doze modules that ask for one, and by "1"
// for the Rust module's `version = 1`; neither depth may drop the other's keys,
// and "1.10" must not sort below "1.9".
func TestMajorsAtTwoDepths(t *testing.T) {
	fulls := []string{"1.1.2", "1.8.2", "1.9.1", "1.10.0", "1.10.0"}
	got := majors(fulls, []int{2, 1})
	want := map[string]string{"1": "1.10.0", "1.1": "1.1.2", "1.8": "1.8.2", "1.9": "1.9.1", "1.10": "1.10.0"}
	if len(got) != len(want) {
		t.Fatalf("majors = %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("majors[%q] = %q, want %q (all: %v)", k, got[k], v, got)
		}
	}
	if one := majors([]string{"16.4.0", "17.1.0"}, []int{0}); one["17"] != "17.1.0" || len(one) != 2 {
		t.Errorf("a single default depth keys by the first part: %v", one)
	}
}

func TestRunnerForOptionalTriples(t *testing.T) {
	c := &config{
		Triples:         map[string]string{"x86_64-unknown-linux-gnu": "ubuntu-22.04"},
		OptionalTriples: map[string]string{"x86_64-pc-windows-msvc": "windows-latest"},
	}
	if c.runnerFor("x86_64-pc-windows-msvc") != "windows-latest" || c.runnerFor("x86_64-unknown-linux-gnu") != "ubuntu-22.04" {
		t.Fatal("runnerFor must find global and optional triples")
	}
	if got := c.triplesFor(engineSpec{}); len(got) != 1 {
		t.Fatalf("an engine naming no triples must not get optional ones: %v", got)
	}
}

func TestArtifactLinesForOneTriple(t *testing.T) {
	index := []byte(`engines:
  temporal:
    versions: {"1": 1.10.0}
    artifacts:
      1.10.0:
        x86_64-pc-windows-msvc: {url: u10, sha256: s10}
      1.9.1:
        x86_64-pc-windows-msvc: {url: u9, sha256: s9}
        aarch64-apple-darwin: {url: m9, sha256: t9}
`)
	got := artifactLines(index, "temporal", "x86_64-pc-windows-msvc")
	want := []string{"1.9.1\tu9\ts9", "1.10.0\tu10\ts10"}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("artifactLines = %q, want %q", got, want)
	}
	if artifactLines(index, "valkey", "x86_64-pc-windows-msvc") != nil {
		t.Fatal("an engine not in the index has no artifacts")
	}
}

func TestRehomeMovesOnlyThisReleasesEntries(t *testing.T) {
	base := "https://github.com/doze-dev/doze-binaries/releases/download/valkey"
	em := &engineManifest{Artifacts: map[string]map[string]artifact{
		"9.1.0": {"aarch64-apple-darwin": {URL: "https://github.com/NerdMeNot/doze-binaries/releases/download/valkey/valkey-9.1.0-aarch64-apple-darwin.tar.gz", SHA256: "s"}},
		"9.1.1": {"aarch64-apple-darwin": {URL: base + "/valkey-9.1.1-aarch64-apple-darwin.tar.gz", SHA256: "t"}},
		"0.0.1": {"x": {URL: "https://example.com/elsewhere/thing.tar.gz", SHA256: "u"}},
	}}
	rehome(em, base)
	if got := em.Artifacts["9.1.0"]["aarch64-apple-darwin"]; got.URL != base+"/valkey-9.1.0-aarch64-apple-darwin.tar.gz" || got.SHA256 != "s" {
		t.Errorf("old-owner entry not rehomed: %+v", got)
	}
	if got := em.Artifacts["9.1.1"]["aarch64-apple-darwin"].URL; got != base+"/valkey-9.1.1-aarch64-apple-darwin.tar.gz" {
		t.Errorf("current entry changed: %s", got)
	}
	if got := em.Artifacts["0.0.1"]["x"].URL; got != "https://example.com/elsewhere/thing.tar.gz" {
		t.Errorf("another release's entry was moved: %s", got)
	}
}
