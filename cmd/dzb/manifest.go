package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// artifact is one downloadable, checksummed archive.
type artifact struct {
	URL    string `yaml:"url"`
	SHA256 string `yaml:"sha256"`
}

// engineManifest mirrors doze's {versions, artifacts} shape for one engine: a
// major resolves to a full version, then a triple to an artifact.
type engineManifest struct {
	Versions  map[string]string              `yaml:"versions"`
	Artifacts map[string]map[string]artifact `yaml:"artifacts"`
}

type manifest struct {
	Engines map[string]*engineManifest `yaml:"engines"`
}

// buildArchiveNameRe compiles the archive-name matcher from the archive prefixes
// declared in versions.yaml (e.g. postgresql|valkey|…), so adding an engine needs
// no edit here. It captures archive-prefix, full version, and triple. The version
// is matched loosely (.+) and the triple is anchored to a known arch+os tail:
// documentdb's version itself contains a dash (e.g. 0.112-0), so a fixed dotted
// pattern can't be used and the triple boundary must be pinned instead.
func buildArchiveNameRe(prefixes []string) *regexp.Regexp {
	quoted := make([]string, len(prefixes))
	for i, p := range prefixes {
		quoted[i] = regexp.QuoteMeta(p)
	}
	return regexp.MustCompile(`^(` + strings.Join(quoted, "|") +
		`)-(.+)-((?:aarch64|x86_64)-(?:apple-darwin|unknown-linux-gnu))\.tar\.gz$`)
}

// runManifest builds the multi-engine index.yaml. It is CUMULATIVE: if an
// existing manifest is given, newly built archives are merged into it and no
// previously published entry is ever dropped or overwritten — so old versions
// stay resolvable forever and lockfiles keep working. The existing manifest may
// be YAML or legacy JSON (JSON is a YAML subset, so the same parser reads both).
func runManifest(args []string) error {
	if len(args) < 2 || len(args) > 3 {
		return fmt.Errorf("usage: dzb manifest <dist_dir> <download_base_url> [existing_index]")
	}
	dist, base := args[0], strings.TrimRight(args[1], "/")
	forced := rebuildSet()

	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	prefixes, toEngine := cfg.archivePrefixes()
	archiveName := buildArchiveNameRe(prefixes)

	man := manifest{Engines: map[string]*engineManifest{}}
	if len(args) == 3 {
		if data, err := os.ReadFile(args[2]); err == nil {
			if err := yaml.Unmarshal(data, &man); err != nil {
				return fmt.Errorf("parsing existing manifest %s: %w", args[2], err)
			}
			if man.Engines == nil {
				man.Engines = map[string]*engineManifest{}
			}
		}
		// A missing existing manifest (first run) is fine: start empty.
	}

	entries, err := os.ReadDir(dist)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := archiveName.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		prefix, full, triple := m[1], m[2], m[3]
		engine := toEngine[prefix] // archive prefix -> engine key (e.g. postgresql -> postgres)
		em := man.Engines[engine]
		if em == nil {
			em = &engineManifest{Versions: map[string]string{}, Artifacts: map[string]map[string]artifact{}}
			man.Engines[engine] = em
		}
		if em.Artifacts == nil {
			em.Artifacts = map[string]map[string]artifact{}
		}
		if em.Artifacts[full] == nil {
			em.Artifacts[full] = map[string]artifact{}
		}
		// Published artifacts are immutable: never overwrite an existing entry —
		// unless it is explicitly listed in DZB_REBUILD (recreating a bad build),
		// in which case we recompute its checksum from the freshly built archive.
		if _, exists := em.Artifacts[full][triple]; exists && !forced(full, triple) {
			continue
		}
		sum, err := sha256File(filepath.Join(dist, e.Name()))
		if err != nil {
			return err
		}
		em.Artifacts[full][triple] = artifact{URL: base + "/" + e.Name(), SHA256: sum}
	}

	// Recompute each engine's major->newest-full map over the full union. The
	// major key depth is per-engine (major_parts): it must match the major the
	// engine's doze module declares, or resolution misses ("no temporal 1.1").
	for name, em := range man.Engines {
		parts := cfg.Engines[name].MajorParts
		em.Versions = map[string]string{}
		for full := range em.Artifacts {
			major := majorKey(full, parts)
			if cur, ok := em.Versions[major]; !ok || versionLess(cur, full) {
				em.Versions[major] = full
			}
		}
	}

	out, err := yaml.Marshal(man)
	if err != nil {
		return err
	}
	fmt.Print(string(out))
	return nil
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// versionLess reports whether version a < b. Segments split on both "." and
// "-" and compare numerically — the dash matters: documentdb versions are
// "0.112-0"-shaped, and a dot-only split would read "112-0" and "112-1" as the
// same number, leaving the major→newest map to map iteration order. Non-numeric
// segments (and a missing vs present segment) fall back to string comparison.
func versionLess(a, b string) bool {
	seg := func(s string) []string {
		return strings.FieldsFunc(s, func(r rune) bool { return r == '.' || r == '-' })
	}
	as, bs := seg(a), seg(b)
	for i := 0; i < len(as) || i < len(bs); i++ {
		var av, bv string
		if i < len(as) {
			av = as[i]
		}
		if i < len(bs) {
			bv = bs[i]
		}
		ai, aerr := strconv.Atoi(av)
		bi, berr := strconv.Atoi(bv)
		if aerr == nil && berr == nil {
			if ai != bi {
				return ai < bi
			}
			continue
		}
		if av != bv {
			return av < bv
		}
	}
	return false
}
