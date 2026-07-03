package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// runEngines prints the engine keys from versions.yaml as a JSON array, so the
// release workflow's build matrix is derived from the catalog rather than a
// hardcoded list — adding an engine is one versions.yaml entry plus a recipe.
func runEngines(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	out, err := json.Marshal(cfg.engineNames())
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
}

// runLatest prints "<archiveVersion> <ref>" for an engine's newest declared
// version (the last entry — versions.yaml only ever appends). PR CI uses it to
// build+smoke exactly the recipe under change, regardless of publish state.
func runLatest(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: dzb latest <engine>")
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	spec, ok := cfg.Engines[args[0]]
	if !ok {
		return fmt.Errorf("unknown engine %q (not in versions.yaml)", args[0])
	}
	if len(spec.Versions) == 0 {
		return fmt.Errorf("engine %q has no versions", args[0])
	}
	v := spec.Versions[len(spec.Versions)-1]
	fmt.Printf("%s %s\n", spec.archiveVersion(v), spec.ref(v))
	return nil
}

// engineSpec is one engine's declarative build rule, read verbatim from
// versions.yaml. Adding a new backing engine is a single entry here plus a
// recipe — plan/manifest/engines all derive their behaviour from these fields,
// so there is no second list to keep in sync.
type engineSpec struct {
	Versions []string `yaml:"versions"`
	// Ref is the source ref template built from the upstream version. Placeholders:
	//   {v}  -> the version verbatim (e.g. 2.7.0)
	//   {v_} -> the version with dots replaced by underscores (e.g. 16_14)
	// Default "{v}".  Examples: postgres "REL_{v_}", kvrocks/ferretdb "v{v}".
	Ref string `yaml:"ref"`
	// ArchiveSuffix is appended to the version to form the archive's version field
	// (e.g. postgres builds 16.14 as archive 16.14.0 with suffix ".0"). Default "".
	ArchiveSuffix string `yaml:"archive_suffix"`
	// ArchiveName is the on-disk archive prefix when it differs from the engine key
	// (postgres archives are named "postgresql"). Default: the engine key.
	ArchiveName string `yaml:"archive_name"`
	// Triples restricts the engine to a subset of the global triples — for an
	// engine whose upstream only publishes some platforms (mariadb: upstream
	// generic tarballs are x86_64-linux only). Default: every global triple.
	Triples []string `yaml:"triples"`
}

// triplesFor returns the engine's build triples: its own restriction when set,
// else every global triple — in stable order either way.
func (c *config) triplesFor(spec engineSpec) []string {
	if len(spec.Triples) > 0 {
		out := append([]string(nil), spec.Triples...)
		sort.Strings(out)
		return out
	}
	out := make([]string, 0, len(c.Triples))
	for t := range c.Triples {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}

// config mirrors versions.yaml. Versions are explicit — dzb does no upstream
// resolution. It is the cumulative catalog of everything that should be
// published; entries are only ever added.
type config struct {
	Triples map[string]string     `yaml:"triples"`
	Engines map[string]engineSpec `yaml:"engines"`
}

func loadConfig() (*config, error) {
	data, err := os.ReadFile("versions.yaml")
	if err != nil {
		return nil, err
	}
	var cfg config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing versions.yaml: %w", err)
	}
	return &cfg, nil
}

// engineNames returns the config's engine keys in a stable order so every
// emitted list (matrix, plan) is deterministic.
func (c *config) engineNames() []string {
	out := make([]string, 0, len(c.Engines))
	for e := range c.Engines {
		out = append(out, e)
	}
	sort.Strings(out)
	return out
}

// archiveVersion applies the engine's archive_suffix to an upstream version.
func (s engineSpec) archiveVersion(v string) string { return v + s.ArchiveSuffix }

// ref expands the engine's ref template for an upstream version.
func (s engineSpec) ref(v string) string {
	tmpl := s.Ref
	if tmpl == "" {
		tmpl = "{v}"
	}
	tmpl = strings.ReplaceAll(tmpl, "{v_}", strings.ReplaceAll(v, ".", "_"))
	tmpl = strings.ReplaceAll(tmpl, "{v}", v)
	return tmpl
}

// archiveName returns the on-disk archive prefix for an engine (defaults to the
// engine key), plus the reverse map (archive prefix -> engine key) used to
// normalise scanned archive names back to engine keys.
func (c *config) archivePrefixes() (prefixes []string, toEngine map[string]string) {
	toEngine = map[string]string{}
	for _, e := range c.engineNames() {
		p := c.Engines[e].ArchiveName
		if p == "" {
			p = e
		}
		prefixes = append(prefixes, p)
		toEngine[p] = e
	}
	return prefixes, toEngine
}
