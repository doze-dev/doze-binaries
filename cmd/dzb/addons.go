package main

import (
	"crypto/ed25519"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Add-on indexes.
//
// An add-on is something a module installs into its engine at run time: a
// Postgres extension today. Its catalog is versions.yaml (`extensions:`), the
// one place doze describes it; this file publishes that catalog as a signed
// add-on index, the shape of design section 3.3 ("module add-ons and
// compatibility"):
//
//	schema: 1
//	index: postgres-extensions        # also its release tag and file stem
//	engine: postgres                  # the engine the add-ons go into
//	noun: extension                   # what the module calls them
//	addons:
//	  vector:
//	    aliases: [pgvector]
//	    wave: 1
//	    description: …
//	    license: PostgreSQL
//	    homepage: …
//	    line: "0.8"                   # default line (newest top-level version)
//	    lines: {"14": "1.4"}          # per-major line, where a major has its own
//	    majors: ["14", …, "18"]
//	    preload / may_preload / settings / env / requires / provides / note
//	    releases:
//	      0.8.7:
//	        engines: ["14", …, "18"]
//	        artifacts:
//	          "17": {aarch64-apple-darwin: {url, sha256, sig}, …}
//	    channels: {stable: 0.8.7}
//	signature: …                      # sign.go: whole document, canonical JSON
//
// Artifacts come from the published per-bundle mirror indexes
// (pgext-<name>-pg<major>/index.yaml), which doze's Go module still reads, so
// the add-on index adds a view and moves nothing. It lists only what exists:
// generating it fails when a catalogued (extension, major, version, triple)
// has no artifact, or a mirror artifact has no catalog entry — so an
// extension that passes doze's name check can always be fetched.

const (
	addonSchema = 1
	// pgAddonIndex names the Postgres extension index: its `index` field, its
	// release tag and the path doze fetches, <mirror root>/<index>/index.yaml.
	pgAddonIndex = "postgres-extensions"
)

type addonIndex struct {
	Schema    int                   `yaml:"schema"`
	Index     string                `yaml:"index"`
	Engine    string                `yaml:"engine"`
	Noun      string                `yaml:"noun"`
	Addons    map[string]addonEntry `yaml:"addons"`
	Signature string                `yaml:"signature,omitempty"`
}

type addonEntry struct {
	Aliases     []string            `yaml:"aliases,omitempty"`
	Wave        int                 `yaml:"wave"`
	Description string              `yaml:"description"`
	License     string              `yaml:"license"`
	Homepage    string              `yaml:"homepage"`
	Line        string              `yaml:"line,omitempty"`
	Lines       map[string]string   `yaml:"lines,omitempty"`
	Majors      []string            `yaml:"majors"`
	Preload     []string            `yaml:"preload,omitempty"`
	MayPreload  []string            `yaml:"may_preload,omitempty"`
	Settings    map[string]string   `yaml:"settings,omitempty"`
	Env         map[string]string   `yaml:"env,omitempty"`
	Requires    []string            `yaml:"requires,omitempty"`
	Provides    map[string][]string `yaml:"provides,omitempty"`
	Note        string              `yaml:"note,omitempty"`
	// Bundled: the third-party libraries shipped inside every bundle, with
	// licence and exact source (the GPL corresponding-source record).
	Bundled  []bundledLib        `yaml:"bundled,omitempty"`
	Releases map[string]addonRel `yaml:"releases"`
	Channels map[string]string   `yaml:"channels"`
}

type addonRel struct {
	// Engines are the engine majors this release is built for.
	Engines []string `yaml:"engines"`
	// Sources: engine major -> the exact upstream source it was built from,
	// <repo>@<ref> (the same string as bundle.json source), so the source of
	// every artifact is findable from the signed index.
	Sources map[string]string `yaml:"sources"`
	// Artifacts: engine major -> triple -> archive.
	Artifacts map[string]map[string]artifact `yaml:"artifacts"`
}

// newestVersion is the highest of vs by versionLess ("" for none).
func newestVersion(vs []string) string {
	best := ""
	for _, v := range vs {
		if best == "" || versionLess(best, v) {
			best = v
		}
	}
	return best
}

// addonMeta is an entry's catalog metadata, with lines and majors derived
// from the build fields (so they can't disagree with what is built). The line
// fields follow the Go module catalog: `line` when the extension has
// top-level versions, `lines` for each major with a line of its own.
func addonMeta(s extSpec) addonEntry {
	e := addonEntry{
		Aliases: s.Aliases, Wave: s.Wave, Description: s.Description,
		License: s.License, Homepage: s.Homepage,
		Preload: s.Preload, MayPreload: s.MayPreload, Settings: s.Settings,
		Env: s.Env, Requires: s.Requires, Provides: s.Provides, Note: strings.TrimSpace(s.Note),
		Bundled:  s.Bundled,
		Releases: map[string]addonRel{}, Channels: map[string]string{},
	}
	if len(s.Versions) > 0 {
		e.Line = majorKey(newestVersion(s.Versions), 2)
	}
	for _, m := range s.majors() {
		e.Majors = append(e.Majors, strconv.Itoa(m))
		if l, ok := s.Lines[m]; ok {
			if e.Lines == nil {
				e.Lines = map[string]string{}
			}
			e.Lines[strconv.Itoa(m)] = majorKey(newestVersion(l.Versions), 2)
		}
	}
	// Provides values must be lists, never null: an empty requirement list is
	// still a list (canonical JSON has no null).
	for k, v := range e.Provides {
		if v == nil {
			e.Provides[k] = []string{}
		}
	}
	return e
}

// checkAddons is the static half of the catalog <-> build check, needing no
// network: every built entry has a recipe smoke test, every recipe directory
// has a catalog entry, names and aliases are unique, and requirements point at
// something that will be there. root is the repository root.
func (c *config) checkAddons(root string) []string {
	var problems []string
	add := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }

	names := make([]string, 0, len(c.Extensions))
	for n := range c.Extensions {
		names = append(names, n)
	}
	sort.Strings(names)

	// Every name a user can write, and what it means.
	owner := map[string]string{}
	claim := func(name, by string) {
		if prev, ok := owner[name]; ok {
			add("%q is claimed twice (%s and %s)", name, prev, by)
			return
		}
		owner[name] = by
	}
	for _, n := range names {
		claim(n, n)
	}
	for _, n := range names {
		s := c.Extensions[n]
		for _, a := range s.Aliases {
			claim(a, n+" (alias)")
		}
		for p := range s.Provides {
			claim(p, n+" (provides)")
		}
	}

	// Built entries: a recipe smoke test, and requirements that are built too
	// and exist for every major the entry is built for.
	for _, n := range names {
		s := c.Extensions[n]
		if !c.waveBuilt(s.Wave) {
			continue
		}
		if _, err := os.Stat(filepath.Join(root, "recipes", "pgext", n, "smoke.sql")); err != nil {
			add("%s is in the built set (wave %d) but has no recipes/pgext/%s/smoke.sql: nothing would verify it", n, s.Wave, n)
		}
		reqs := append([]string(nil), s.Requires...)
		for _, pr := range s.Provides {
			reqs = append(reqs, pr...)
		}
		for _, r := range reqs {
			if r == n {
				continue // a provided name requiring its own bundle
			}
			dep, ok := c.Extensions[r]
			if !ok {
				continue // contrib (ships in every Postgres) or provided by this bundle
			}
			if !c.waveBuilt(dep.Wave) {
				add("%s requires %s, which is wave %d and not built", n, r, dep.Wave)
				continue
			}
			have := map[int]bool{}
			for _, m := range dep.majors() {
				have[m] = true
			}
			for _, m := range s.majors() {
				if !have[m] {
					add("%s is built for Postgres %d but requires %s, which is not", n, m, r)
				}
			}
		}
	}

	// Bundle dependencies: no cycles, and at most two build stages (the
	// release workflow has a stage-1 and a stage-2 build job, nothing deeper).
	for _, n := range c.builtExtensions() {
		for _, d := range c.bundleDeps(n) {
			if contains(c.bundleDeps(d), n) {
				add("%s and %s need each other's bundles: a cycle no build order satisfies", n, d)
			}
		}
		if st := c.buildStage(n); st > 2 {
			add("%s is build stage %d; build-pgext.yml builds two stages", n, st)
		}
	}

	// Every recipe directory belongs to a catalog entry.
	dirs, err := os.ReadDir(filepath.Join(root, "recipes", "pgext"))
	if err != nil {
		add("reading recipes/pgext: %v", err)
	}
	for _, d := range dirs {
		if d.IsDir() {
			if _, ok := c.Extensions[d.Name()]; !ok {
				add("recipes/pgext/%s has no catalog entry in versions.yaml extensions", d.Name())
			}
		}
	}

	// The metadata must sign portably (no control characters, no floats).
	meta := map[string]addonEntry{}
	for _, n := range c.builtExtensions() {
		meta[n] = addonMeta(c.Extensions[n])
	}
	if body, err := yaml.Marshal(addonIndex{Schema: addonSchema, Index: pgAddonIndex, Engine: "postgres", Noun: "extension", Addons: meta}); err != nil {
		add("rendering the index: %v", err)
	} else if _, err := documentDigest(body); err != nil {
		add("%v", err)
	}
	return problems
}

// mirrorSource reads a bundle engine's published mirror index: dir/<engine>/
// index.yaml when dir holds one (the publish job's freshly merged indexes),
// else <root>/<engine>/index.yaml.
type mirrorSource struct {
	dir  string
	root string
}

func (m mirrorSource) read(engine string) ([]byte, string, error) {
	if m.dir != "" {
		p := filepath.Join(m.dir, engine, "index.yaml")
		if b, err := os.ReadFile(p); err == nil {
			return b, p, nil
		}
	}
	loc := strings.TrimRight(m.root, "/") + "/" + engine + "/index.yaml"
	b, found, err := fetchIndex(loc)
	if err != nil {
		return nil, loc, err
	}
	if !found {
		return nil, loc, nil
	}
	return b, loc, nil
}

func defaultMirrorRoot() string {
	if r := os.Getenv("DZB_MIRROR"); r != "" {
		return r
	}
	repo := os.Getenv("GITHUB_REPOSITORY")
	if repo == "" {
		repo = "doze-dev/doze-binaries"
	}
	return "https://github.com/" + repo + "/releases/download"
}

// buildAddonIndex assembles the Postgres extension index from the catalog and
// the mirror indexes, and fails, naming every gap, when the two disagree.
// With pub set, every mirror index read must carry a valid signature by it.
func (c *config) buildAddonIndex(src mirrorSource, pub ed25519.PublicKey) (*addonIndex, error) {
	idx := &addonIndex{
		Schema: addonSchema, Index: pgAddonIndex, Engine: "postgres", Noun: "extension",
		Addons: map[string]addonEntry{},
	}
	triples := c.triplesFor(engineSpec{}) // bundles take the global triples
	var problems []string
	add := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }

	for _, name := range c.builtExtensions() {
		spec := c.Extensions[name]
		entry := addonMeta(spec)
		var all []string
		for _, major := range spec.majors() {
			engine := pgextEngineKey(name, major)
			mkey := strconv.Itoa(major)
			body, loc, err := src.read(engine)
			if err != nil {
				return nil, err
			}
			if body == nil {
				add("%s: no published index at %s (catalogued for Postgres %d, never built)", name, loc, major)
				continue
			}
			if pub != nil {
				if _, err := verifyDocument(body, pub); err != nil {
					add("%s: %v", loc, err)
				}
			}
			var man manifest
			if err := yaml.Unmarshal(body, &man); err != nil {
				return nil, fmt.Errorf("parsing %s: %w", loc, err)
			}
			em := man.Engines[engine]
			if em == nil {
				add("%s: %s has no %s engine", name, loc, engine)
				continue
			}
			for other := range man.Engines {
				if other != engine {
					add("%s: %s also lists engine %s, which it should not", name, loc, other)
				}
			}
			versions, refTmpl := spec.forMajor(major)
			want := map[string]bool{}
			for _, v := range versions {
				want[v] = true
				arts := em.Artifacts[v]
				for _, t := range triples {
					a, ok := arts[t]
					if !ok {
						add("%s %s for Postgres %d: no %s artifact", name, v, major, t)
						continue
					}
					rel := entry.Releases[v]
					if rel.Artifacts == nil {
						rel.Artifacts = map[string]map[string]artifact{}
					}
					if rel.Artifacts[mkey] == nil {
						rel.Artifacts[mkey] = map[string]artifact{}
					}
					rel.Artifacts[mkey][t] = artifact{URL: a.URL, SHA256: strings.ToLower(a.SHA256)}
					if rel.Sources == nil {
						rel.Sources = map[string]string{}
					}
					rel.Sources[mkey] = spec.Repo + "@" + engineSpec{Ref: refTmpl}.ref(v)
					entry.Releases[v] = rel
				}
				for t := range arts {
					if !contains(triples, t) {
						add("%s %s for Postgres %d: artifact for %s, a triple the catalog does not build", name, v, major, t)
					}
				}
			}
			for v := range em.Artifacts {
				if !want[v] {
					add("%s: %s has version %s, which versions.yaml does not catalogue for Postgres %d", name, loc, v, major)
				}
			}
			all = append(all, versions...)
		}
		// A release's engines are the majors it has artifacts for: the
		// complete set, given the checks above.
		for v, rel := range entry.Releases {
			rel.Engines = nil
			for m := range rel.Artifacts {
				rel.Engines = append(rel.Engines, m)
			}
			sort.Slice(rel.Engines, func(i, j int) bool { return versionLess(rel.Engines[i], rel.Engines[j]) })
			entry.Releases[v] = rel
		}
		if stable := newestVersion(all); stable != "" {
			entry.Channels["stable"] = stable
		}
		idx.Addons[name] = entry
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return nil, fmt.Errorf("the catalog and the published bundles disagree:\n  %s", strings.Join(problems, "\n  "))
	}
	return idx, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// renderAddonIndex marshals the index, signing every artifact and the
// document when priv is set.
func renderAddonIndex(idx *addonIndex, priv ed25519.PrivateKey) ([]byte, error) {
	idx.Signature = ""
	for _, e := range idx.Addons {
		for _, rel := range e.Releases {
			for _, triples := range rel.Artifacts {
				for t, a := range triples {
					a.Sig = ""
					if priv != nil {
						a.Sig = signHex(priv, a.SHA256)
					}
					triples[t] = a
				}
			}
		}
	}
	body, err := yaml.Marshal(idx)
	if err != nil {
		return nil, err
	}
	if _, err := documentDigest(body); err != nil {
		return nil, err
	}
	if priv == nil {
		return body, nil
	}
	return signDocument(body, priv)
}

// runAddons is `dzb addons check | index [--indexes <dir>] [--unsigned]`.
//
//	check   the static catalog <-> recipe check (CI, every PR)
//	index   the signed postgres-extensions index on stdout, built from the
//	        mirror indexes (dir/<engine>/index.yaml when present, else the
//	        published <DZB_MIRROR or this repo's releases>/<engine>/index.yaml)
//	        and signed with DZB_SIGNING_KEY; --unsigned for a local preview.
func runAddons(args []string) error {
	usage := fmt.Errorf("usage: dzb addons check | dzb addons index [--indexes <dir>] [--unsigned]")
	if len(args) == 0 {
		return usage
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	if p := cfg.checkAddons("."); len(p) > 0 {
		return fmt.Errorf("versions.yaml extensions:\n  %s", strings.Join(p, "\n  "))
	}
	switch args[0] {
	case "check":
		if len(args) != 1 {
			return usage
		}
		fmt.Printf("addons: %d catalogued, %d built (waves %v): ok\n", len(cfg.Extensions), len(cfg.builtExtensions()), cfg.ExtensionWaves)
		return nil
	case "index":
		src := mirrorSource{root: defaultMirrorRoot()}
		unsigned := false
		for i := 1; i < len(args); i++ {
			switch args[i] {
			case "--indexes":
				if i+1 >= len(args) {
					return usage
				}
				i++
				src.dir = args[i]
			case "--unsigned":
				unsigned = true
			default:
				return usage
			}
		}
		var priv ed25519.PrivateKey
		var pub ed25519.PublicKey
		if !unsigned {
			if priv, err = signingKey(); err != nil {
				return err
			}
			pub = priv.Public().(ed25519.PublicKey)
		}
		idx, err := cfg.buildAddonIndex(src, pub)
		if err != nil {
			return err
		}
		out, err := renderAddonIndex(idx, priv)
		if err != nil {
			return err
		}
		fmt.Print(string(out))
		return nil
	}
	return usage
}
