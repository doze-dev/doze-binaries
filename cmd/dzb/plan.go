package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// matrixItem is one (engine, version, triple) build job.
type matrixItem struct {
	Engine  string `json:"engine"`
	Version string `json:"version"`
	Ref     string `json:"ref"`
	Triple  string `json:"triple"`
	Runner  string `json:"runner"`
}

func runPlan(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	// Optional engine filter — per-engine workflows pass a single engine.
	engines := cfg.engineNames()
	if len(args) > 0 && args[0] != "" {
		if _, ok := cfg.Engines[args[0]]; !ok {
			return fmt.Errorf("unknown engine %q (not in versions.yaml)", args[0])
		}
		engines = []string{args[0]}
	}

	include := []matrixItem{}
	for _, engine := range engines {
		spec := cfg.Engines[engine]
		// Already-published artifacts are immutable; never rebuild them (a rebuild
		// would change a checksum and break every lockfile that pinned it).
		published, err := publishedArtifacts(engine)
		if err != nil {
			return err
		}
		forced := rebuildSet()
		// Stable triple order so the emitted matrix is deterministic; an engine
		// may restrict its platforms (see engineSpec.Triples).
		triples := cfg.triplesFor(spec)
		for _, v := range spec.Versions {
			full := spec.archiveVersion(v)
			for _, t := range triples {
				if published[key(engine, full, t)] && !forced(full, t) {
					continue // already built and frozen (DZB_REBUILD overrides)
				}
				include = append(include, matrixItem{
					Engine: engine, Version: full, Ref: spec.ref(v),
					Triple: t, Runner: cfg.Triples[t],
				})
			}
		}
	}

	// GitHub hard-caps a job matrix at 256 entries and FAILS SILENTLY past it
	// (the workflow just doesn't expand). A full-catalog backfill gets close
	// (postgres: 74 versions x 3 triples = 222), so refuse loudly instead of
	// letting a catalog addition wedge the release: stage the new versions
	// across two pushes (the first publish shrinks the second plan).
	const matrixCap = 256
	if len(include) > matrixCap {
		return fmt.Errorf("plan has %d jobs, over GitHub's %d-per-matrix limit — stage the catalog additions across smaller pushes", len(include), matrixCap)
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

	// Reuse the manifest schema from manifest.go — a second declaration of the
	// index shape here could silently drift from the one the publisher writes.
	var idx manifest
	if err := yaml.Unmarshal(body, &idx); err != nil {
		return nil, fmt.Errorf("parsing published manifest: %w", err)
	}
	for engine, e := range idx.Engines {
		if e == nil {
			continue
		}
		for full, triples := range e.Artifacts {
			for triple := range triples {
				set[key(engine, full, triple)] = true
			}
		}
	}
	return set, nil
}

// indexHTTP bounds the published-manifest fetch — without it a hung GitHub
// response stalls the plan job until the job-level timeout.
var indexHTTP = &http.Client{Timeout: 60 * time.Second}

// fetchIndex reads a manifest from an http(s) URL or a local path. found is
// false (with nil error) when the manifest simply isn't there (404 / missing).
func fetchIndex(loc string) (body []byte, found bool, err error) {
	if strings.HasPrefix(loc, "http://") || strings.HasPrefix(loc, "https://") {
		resp, err := indexHTTP.Get(loc)
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
