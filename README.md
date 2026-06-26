# doze-binaries

Prebuilt database-engine binaries for [doze](https://github.com/doze-dev/doze) —
built in CI, published to a rolling GitHub release, and consumed by doze as a
binary **mirror**. No third-party repackagers: doze controls the whole chain.

**Engines & platforms**

| Engine | What we ship | How it's produced |
|---|---|---|
| **PostgreSQL** | one minor per major, 14–17 | built from source (`git.postgresql.org`) |
| **Valkey** | two majors (8.x, 9.x) | built from source (no upstream binaries) |
| **Kvrocks** | 2.x | built from source (RocksDB-backed; the slow one) |
| **FerretDB** | 2.x | cross-compiled from source (pure Go) |

Exact versions are **pinned explicitly** in [`versions.yaml`](versions.yaml) —
nothing is auto-resolved, so a release builds precisely what's listed and every
change is a reviewable diff.

Targets (4 triples, all on native runners — no cross-compilation/emulation):

| Triple | Runner |
|---|---|
| `x86_64-unknown-linux-gnu` | `ubuntu-22.04` |
| `aarch64-unknown-linux-gnu` | `ubuntu-22.04-arm` |
| `x86_64-apple-darwin` | `macos-13` |
| `aarch64-apple-darwin` | `macos-14` |

> **glibc floor.** Linux binaries link the system glibc dynamically, so they
> require a glibc at least as new as the build runner's (Ubuntu 22.04 → glibc
> 2.35). All other non-system libraries are bundled and the rpath is rewritten to
> `$ORIGIN/../lib`, so the trees are otherwise relocatable. macOS builds bundle
> their Homebrew dylibs and are ad-hoc codesigned.

## Layout

```
versions.yaml              build policy (which majors / how many latest majors)
cmd/dzb/                   Go tool for the data work (no drift with doze's schema):
  plan.go                    resolve upstream versions -> CI build matrix
  manifest.go                dist/*.tar.gz -> index.yaml (per-engine manifest)
scripts/                   shell, for orchestrating CLIs:
  package.sh                 tar.gz + .sha256 a staged install dir
  bundle-linux-deps.sh       copy non-system .so + patchelf rpath
  bundle-macos-deps.sh       install_name_tool relocation + ad-hoc codesign
recipes/<engine>/build.sh  build one (version, triple) into an archive
.github/workflows/release.yml   plan -> build matrix -> publish
```

The split is deliberate: shell orchestrates CLI tools (`tar`, `patchelf`,
`configure && make`, …), where it's the right tool; the Go `dzb` tool owns the
*data work* — version resolution and the manifest schema — where types and tests
pay off. The manifest format intentionally mirrors doze's own
`internal/binaries`, and the plan is to fold `dzb manifest` into doze's
`mirror-index` command so there is a single definition shared by producer and
consumer.

Archive naming: `<engine>-<full>-<triple>.tar.gz` (PostgreSQL keeps the
`postgresql-` prefix and a three-part version for doze compatibility).

## The manifest

Each engine has its own rolling release (tag = the engine name), and `dzb
manifest` emits that engine's `index.yaml`, served alongside its archives. It
nests doze's `{versions, artifacts}` shape under the engine key:

```yaml
engines:
  postgres:
    versions:
      "16": 16.9.0
    artifacts:
      16.9.0:
        x86_64-unknown-linux-gnu:
          url: https://.../postgresql-16.9.0-x86_64-unknown-linux-gnu.tar.gz
          sha256: "..."
```

(The schema is multi-engine so a combined manifest also validates, but each
release ships only its own engine's slice.)

## Using it from doze

doze resolves each engine from its own release base — `…/releases/download/<engine>`
— by default, so no configuration is needed. To point at a fork or internal
mirror, override per engine (used as-is) or globally (the engine name is
appended):

```sh
export DOZE_POSTGRES_MIRROR=https://github.com/you/doze-binaries/releases/download/postgres
export DOZE_MIRROR=https://bin.mycorp.dev        # ...mycorp.dev/postgres, /valkey, ...
```

doze resolves a major version through `index.yaml`, downloads the per-triple
archive, verifies its SHA-256, and records the pin in `doze.lock`.

## Releasing

Run the **release** workflow — manual dispatch, or automatically when
`versions.yaml`, `recipes/`, `scripts/`, or `cmd/` change on `main`.

To publish new versions, **add** entries to `versions.yaml` and push. A release
builds only the entries not already published, merges them into the engine's
`index.yaml`, and appends the new archives to that engine's rolling release.

To **recreate** an already-published artifact (e.g. a bad build), dispatch the
release workflow with the `rebuild` input — `16.14.0` for every triple of that
version, or `16.14.0:aarch64-apple-darwin` for one. This is the only way to
overwrite a published artifact; note it changes the checksum, so any `doze.lock`
pinned to the old build must be re-resolved.

### Append-only & immutable (why old versions keep working)

A binaries mirror is only useful if `doze.lock` files keep resolving years later,
so publishing is strictly **append-only**:

- **Never rebuilt.** `dzb plan` skips any `(engine, version, triple)` already in
  the published `index.yaml` (unless explicitly forced via the `rebuild` input).
  Builds aren't bit-reproducible, so rebuilding changes a checksum and breaks
  every lockfile that pinned it — we never do it implicitly.
- **Never dropped.** `dzb manifest` *merges* new archives into the existing
  published manifest; removing a line from `versions.yaml` does **not** remove
  the published binary (so don't expect it to — the catalog only grows).
- **Never deleted.** Only `index.yaml` is overwritten on publish; existing
  version archives are left untouched.

Because archive URLs are deterministic (`<base>/<engine>-<full>-<triple>.tar.gz`),
doze can re-fetch any locked version directly and verify it against the lock's
checksum — independent of the manifest. `index.yaml` is for *discovery* and
resolving a bare major; a pinned version installs as long as its frozen archive
exists, which is forever.

> **Status:** first-pass recipes. From-source multi-engine builds always need a
> CI shakeout — expect to tune apt/brew package lists and a few flags on the
> first green run.
