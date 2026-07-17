// Command dzb is the build-orchestration tool for doze-binaries. It has three
// subcommands used by the release workflow:
//
//	dzb plan                       resolve upstream versions -> CI build matrix JSON
//	dzb manifest <dist> <baseURL>  scan built archives -> multi-engine index.json
//	dzb engines                    the engine keys from versions.yaml -> JSON array
//	dzb latest <engine>            "<archiveVersion> <ref>" of the newest version
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
		fatal("usage: dzb <plan|manifest|engines|latest> [args]")
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
	default:
		fatal("unknown command %q (want plan|manifest|engines|latest)", os.Args[1])
	}
	if err != nil {
		fatal("%v", err)
	}
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "dzb: "+format+"\n", args...)
	os.Exit(1)
}
