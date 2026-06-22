package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// config mirrors versions.yaml. Versions are explicit — dzb plan does no
// upstream resolution. It is the cumulative catalog of everything that should
// be published; entries are only ever added.
type config struct {
	Triples map[string]string `yaml:"triples"`
	Engines map[string]struct {
		Versions []string `yaml:"versions"`
	} `yaml:"engines"`
}

// matrixItem is one (engine, version, triple) build job.
type matrixItem struct {
	Engine  string `json:"engine"`
	Version string `json:"version"`
	Ref     string `json:"ref"`
	Triple  string `json:"triple"`
	Runner  string `json:"runner"`
}

// engineRule derives, from the upstream version written in versions.yaml, the
// three-part version used in the archive name and the source ref to build.
type engineRule struct {
	archiveVersion func(string) string
	ref            func(string) string
}

// engineOrder fixes engine iteration order so the emitted matrix is deterministic.
var engineOrder = []string{"postgres", "valkey", "kvrocks", "ferretdb", "documentdb"}

var engineRules = map[string]engineRule{
	// Postgres: real two-part version (16.14) -> archive 16.14.0, branch REL_16_14.
	"postgres": {
		archiveVersion: func(v string) string { return v + ".0" },
		ref:            func(v string) string { return "REL_" + strings.ReplaceAll(v, ".", "_") },
	},
	// Valkey tags carry no leading "v".
	"valkey": {
		archiveVersion: func(v string) string { return v },
		ref:            func(v string) string { return v },
	},
	// Kvrocks and FerretDB tags are "vX.Y.Z".
	"kvrocks": {
		archiveVersion: func(v string) string { return v },
		ref:            func(v string) string { return "v" + v },
	},
	"ferretdb": {
		archiveVersion: func(v string) string { return v },
		ref:            func(v string) string { return "v" + v },
	},
	// DocumentDB tags are "vX.Y-Z" (e.g. v0.112-0); the version string keeps the
	// dash and is used verbatim in the archive name.
	"documentdb": {
		archiveVersion: func(v string) string { return v },
		ref:            func(v string) string { return "v" + v },
	},
}

func runPlan(args []string) error {
	data, err := os.ReadFile("versions.yaml")
	if err != nil {
		return err
	}
	var cfg config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("parsing versions.yaml: %w", err)
	}

	// Catch typos: any engine in the config we don't know how to build.
	for engine := range cfg.Engines {
		if _, ok := engineRules[engine]; !ok {
			return fmt.Errorf("unknown engine %q in versions.yaml", engine)
		}
	}

	// Optional engine filter — per-engine workflows pass a single engine.
	engines := engineOrder
	if len(args) > 0 && args[0] != "" {
		if _, ok := engineRules[args[0]]; !ok {
			return fmt.Errorf("unknown engine %q", args[0])
		}
		engines = []string{args[0]}
	}

	// Stable triple order so the emitted matrix is deterministic.
	triples := make([]string, 0, len(cfg.Triples))
	for t := range cfg.Triples {
		triples = append(triples, t)
	}
	sort.Strings(triples)

	include := []matrixItem{}
	for _, engine := range engines {
		spec, ok := cfg.Engines[engine]
		if !ok {
			continue
		}
		// Already-published artifacts are immutable; never rebuild them (a rebuild
		// would change a checksum and break every lockfile that pinned it).
		published, err := publishedArtifacts(engine)
		if err != nil {
			return err
		}
		forced := rebuildSet()
		rule := engineRules[engine]
		for _, v := range spec.Versions {
			full := rule.archiveVersion(v)
			for _, t := range triples {
				if published[key(engine, full, t)] && !forced(full, t) {
					continue // already built and frozen (DZB_REBUILD overrides)
				}
				include = append(include, matrixItem{
					Engine: engine, Version: full, Ref: rule.ref(v),
					Triple: t, Runner: cfg.Triples[t],
				})
			}
		}
	}

	out, err := json.Marshal(struct {
		Include []matrixItem `json:"include"`
	}{include})
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
}

func key(engine, full, triple string) string { return engine + "|" + full + "|" + triple }

// rebuildSet parses DZB_REBUILD — a comma-separated list of artifacts to rebuild
// even though they are already published (for fixing a bad build). Each token is
// a full version ("16.14.0", matching every triple) or "full:triple"
// ("16.14.0:aarch64-apple-darwin", just that one). forced reports whether a given
// (full, triple) should be rebuilt/overwritten.
func rebuildSet() func(full, triple string) bool {
	raw := strings.TrimSpace(os.Getenv("DZB_REBUILD"))
	if raw == "" {
		return func(string, string) bool { return false }
	}
	fulls := map[string]bool{}
	pairs := map[string]bool{}
	for _, tok := range strings.Split(raw, ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" {
			continue
		}
		if full, triple, ok := strings.Cut(tok, ":"); ok {
			pairs[full+"|"+triple] = true
		} else {
			fulls[tok] = true
		}
	}
	return func(full, triple string) bool {
		return fulls[full] || pairs[full+"|"+triple]
	}
}

// publishedArtifacts returns the set of (engine, full, triple) already present
// in the published manifest, so plan can skip them. The manifest location is
// DZB_INDEX_URL (an http(s) URL or a local path), else derived from
// GITHUB_REPOSITORY. The current manifest is index.yaml, but a legacy index.json
// is tried as a fallback so a format migration does not look like "nothing
// published" (which would rebuild everything and break checksums). A missing
// manifest (first ever run) yields an empty set.
func publishedArtifacts(engine string) (map[string]bool, error) {
	set := map[string]bool{}

	var locs []string
	if loc := os.Getenv("DZB_INDEX_URL"); loc != "" {
		locs = []string{loc}
	} else if repo := os.Getenv("GITHUB_REPOSITORY"); repo != "" {
		base := fmt.Sprintf("https://github.com/%s/releases/download/%s", repo, engine)
		locs = []string{base + "/index.yaml", base + "/index.json"}
	}
	if len(locs) == 0 {
		return set, nil // no reference point: treat everything as new
	}

	var body []byte
	for _, loc := range locs {
		b, found, err := fetchIndex(loc)
		if err != nil {
			return nil, err
		}
		if found {
			body = b
			break
		}
	}
	if body == nil {
		return set, nil // not published yet (in any format)
	}

	var idx struct {
		Engines map[string]struct {
			Artifacts map[string]map[string]yaml.Node `yaml:"artifacts"`
		} `yaml:"engines"`
	}
	if err := yaml.Unmarshal(body, &idx); err != nil {
		return nil, fmt.Errorf("parsing published manifest: %w", err)
	}
	for engine, e := range idx.Engines {
		for full, triples := range e.Artifacts {
			for triple := range triples {
				set[key(engine, full, triple)] = true
			}
		}
	}
	return set, nil
}

// fetchIndex reads a manifest from an http(s) URL or a local path. found is
// false (with nil error) when the manifest simply isn't there (404 / missing).
func fetchIndex(loc string) (body []byte, found bool, err error) {
	if strings.HasPrefix(loc, "http") {
		resp, err := http.Get(loc)
		if err != nil {
			return nil, false, fmt.Errorf("fetching published manifest %s: %w", loc, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound {
			return nil, false, nil
		}
		if resp.StatusCode != http.StatusOK {
			return nil, false, fmt.Errorf("fetching published manifest %s: %s", loc, resp.Status)
		}
		b, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, false, err
		}
		return b, true, nil
	}
	b, err := os.ReadFile(loc)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return b, true, nil
}
