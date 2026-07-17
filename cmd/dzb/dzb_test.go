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
