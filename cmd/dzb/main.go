// Command dzb is the build-orchestration tool for doze-binaries. Its
// subcommands, used by the workflows:
//
//	dzb plan                       resolve upstream versions -> CI build matrix JSON
//	dzb manifest <dist> <baseURL>  scan built archives -> multi-engine index.json
//	dzb engines                    the engine keys from versions.yaml -> JSON array
//	dzb latest <engine>            "<archiveVersion> <ref>" of the newest version
//	dzb pgext ...                  build inputs for an extension bundle (pgext.go)
//	dzb pgext-bundle <json> <db> <root>  contract-check a bundle.json, as shell vars
//	dzb verify-plan [engines]      the weekly verify sweep's (engine, triple) matrix
//	dzb artifacts <index> <engine> <triple>  a published index's artifacts, one per line
//	dzb addons check               the catalog <-> recipe check (addons.go)
//	dzb addons index [--indexes d] the signed postgres-extensions add-on index
//	dzb sign <index.yaml>          sign an engine mirror index in place (sign.go)
//	dzb verify-sig <index> <pub|->  check a signed index the way doze will
//	dzb pubkey                     the public half of DZB_SIGNING_KEY
//
// Extension bundles (versions.yaml `extensions:`) are expanded into engines
// keyed pgext-<name>-pg<major>; `engines`/`plan` take --pgext to select them.
//
// The heavier lifting (compiling engines, bundling libraries, packaging) stays
// in shell, which is the better tool for orchestrating CLIs. dzb owns only the
// data work — version resolution and the manifest schema — where Go's types and
// testability pay off.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: dzb <plan|manifest|engines|latest|artifacts|pgext|pgext-bundle|verify-plan|addons|sign|verify-sig|pubkey> [args]")
	}
	var err error
	switch os.Args[1] {
	case "plan":
		err = runPlan(os.Args[2:])
	case "manifest":
		err = runManifest(os.Args[2:])
	case "engines":
		err = runEngines(os.Args[2:])
	case "latest":
		err = runLatest(os.Args[2:])
	case "artifacts":
		err = runArtifacts(os.Args[2:])
	case "pgext":
		err = runPgext(os.Args[2:])
	case "pgext-bundle":
		err = runBundleEnv(os.Args[2:])
	case "verify-plan":
		err = runVerifyPlan(os.Args[2:])
	case "addons":
		err = runAddons(os.Args[2:])
	case "sign":
		err = runSign(os.Args[2:])
	case "verify-sig":
		err = runVerifySig(os.Args[2:])
	case "pubkey":
		err = runPubkey(os.Args[2:])
	default:
		fatal("unknown command %q (want plan|manifest|engines|latest|artifacts|pgext|pgext-bundle|verify-plan|addons|sign|verify-sig|pubkey)", os.Args[1])
	}
	if err != nil {
		fatal("%v", err)
	}
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "dzb: "+format+"\n", args...)
	os.Exit(1)
}
