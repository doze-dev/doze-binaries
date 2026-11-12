#!/usr/bin/env bash
# parity.sh <dir> [waivers_file]
#
# Cross-triple parity gate: for each (engine, version) present in <dir>, prove
# that every triple ships the SAME tree. Recipes promise this in prose — "every
# triple ships an identical tree" — and nothing enforced it, so mariadb's two
# build arms diverged silently: the x86_64 repackage arm shipped auth_pam and
# auth_gssapi but no server-side auth_parsec/auth_mysql_sha2/sha256_password,
# while the aarch64 source arm shipped the mirror image. A user setting
# `plugin_load_add = auth_parsec` got a working server on arm64 and a broken one
# on x86_64. This is the check that would have caught it at release.
#
# <dir> holds either built archives (<prefix>-<version>-<triple>.tar.gz) or
# pre-extracted `tar tzf` listings (<prefix>-<version>-<triple>.lst). Listings
# exist so the verify workflow can reuse the artifacts it already downloads
# instead of pulling the whole back-catalog a second time.
#
# Exits non-zero when a version's triples disagree. With no <waivers_file> the
# check is absolute — that is the mode for FRESHLY BUILT trees, which have no
# excuse for disagreeing. Sweeps over the already-published catalog pass
# scripts/parity-waivers.txt, because a published archive is immutable and a
# divergence that already shipped can only be DECLARED, never repaired.
set -uo pipefail
# sort, comm and the shell must all agree on collation, or comm reports bogus
# differences on paths that only differ in case or punctuation.
export LC_ALL=C

dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: parity.sh <dir> [waivers_file]" >&2; exit 2; }
waivers="${2:-}"   # empty = no divergence is excusable

# The triples doze targets. Matching against a fixed list (rather than splitting
# on dashes) is what makes the name parse unambiguous: documentdb's version is
# itself dash-shaped ("0.112-0"), so only the triple tail is a reliable anchor.
TRIPLES="aarch64-apple-darwin aarch64-unknown-linux-gnu x86_64-apple-darwin x86_64-unknown-linux-gnu x86_64-pc-windows-msvc aarch64-pc-windows-msvc"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# normalize reads a raw `tar tzf` listing and emits the comparable path set:
#
#  - the top-level archive directory is stripped (it embeds the triple)
#  - directory entries are dropped (they differ by tar flavour, and any real
#    directory is implied by the files inside it)
#  - files sitting FLAT in lib/ are dropped: those are the bundled system
#    libraries, which legitimately differ per OS (linux bundles libtinfo.so.6,
#    macOS bundles nothing of the sort) and per version of the build image.
#    smoke.sh's relocation check already proves each one resolves; what has to
#    match here is what the engine SHIPS — bin/, share/, lib/plugin/.
#  - documentdb's prebuilt template cluster (share/documentdb-template/base/)
#    is dropped: those filenames are Postgres relfilenodes, assigned by the
#    initdb that ran on the build machine, so they are unstable BY CONSTRUCTION
#    and nothing outside the cluster ever names one. Everything else in that
#    artifact — binaries, extensions, the template's config — stays gated.
#  - a trailing .dylib is folded to .so so a macOS module compares against its
#    Linux counterpart by name; a trailing .exe is dropped so a Windows program
#    compares against its Unix counterpart.
normalize() {
  local raw stripped
  raw="$(mktemp)"; stripped="$(mktemp)"
  sed -e 's|^\./||' | grep -v '^$' > "$raw"
  # Strip the archive's own top-level directory — its name embeds the triple, so
  # leaving it in would make every path differ. Only strip when every entry
  # really does sit under one directory, so an already-stripped listing isn't
  # quietly mangled a second time (which would eat the `share/` prefix and
  # silently defeat the exclusions below).
  if grep -q '/' "$raw" && [ "$(cut -d/ -f1 "$raw" | sort -u | wc -l | tr -d ' ')" = 1 ]; then
    sed 's|^[^/]*/||' "$raw" > "$stripped"
  else
    cat "$raw" > "$stripped"
  fi
  grep -v '/$' "$stripped" \
    | grep -v '^$' \
    | grep -vE '^lib/[^/]+$' \
    | grep -vE '^share/documentdb-template/base/' \
    | sed -e 's|\.dylib$|.so|' -e 's|\.exe$||' \
    | sort -u
  rm -f "$raw" "$stripped"
}

# waived <prefix> <version>: true when a waiver file was supplied and declares
# this artifact's divergence as already-published and therefore permanent. Each
# waiver line is an engine archive prefix followed by one or more version
# patterns (shell globs), with `#` starting a comment.
waived() {
  local wprefix="$1" wversion="$2" line wp wv
  [ -n "$waivers" ] && [ -f "$waivers" ] || return 1
  while read -r line; do
    line="${line%%#*}"
    # shellcheck disable=SC2086
    set -- $line
    [ $# -ge 2 ] || continue
    wp="$1"; shift
    # Unquoted on purpose: waiver entries ARE globs, so `mariadb 11.4.*` can
    # cover a whole release line.
    # shellcheck disable=SC2254
    case "$wprefix" in $wp) ;; *) continue ;; esac
    for wv in "$@"; do
      # shellcheck disable=SC2254
      case "$wversion" in $wv) return 0 ;; esac
    done
  done < "$waivers"
  return 1
}

# ── Index <dir> into one file per (prefix, version) listing its triples.
groups="$work/groups"; : > "$groups"
for f in "$dir"/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in
    *.tar.gz) stem="${base%.tar.gz}" ;;
    *.lst)    stem="${base%.lst}" ;;
    *)        continue ;;
  esac
  triple=""
  for t in $TRIPLES; do
    case "$stem" in *-"$t") triple="$t"; stem="${stem%-"$t"}"; break ;; esac
  done
  [ -n "$triple" ] || continue            # index.yaml, checksums, anything else
  prefix="${stem%%-*}"                     # engine archive prefix (postgresql, mariadb, …)
  version="${stem#*-}"                     # everything between prefix and triple
  key="$prefix/$version"
  mkdir -p "$work/g/$key"
  case "$base" in
    *.tar.gz) tar tzf "$f" 2>/dev/null | normalize > "$work/g/$key/$triple" ;;
    *.lst)    normalize < "$f" > "$work/g/$key/$triple" ;;
  esac
  # An unreadable archive yields an empty listing, and comparing empty against
  # empty would report a clean pass. Refuse to guess.
  [ -s "$work/g/$key/$triple" ] || {
    echo "parity: $base produced an empty file listing — unreadable archive?" >&2
    exit 2
  }
  grep -qx "$key" "$groups" || echo "$key" >> "$groups"
done

[ -s "$groups" ] || { echo "parity: no comparable archives in $dir"; exit 0; }

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "## parity: same tree across triples"
  echo
  echo "| artifact | triples | result |"
  echo "|---|---|---|"
} >> "$summary"

bad=0; nwaived=0
while IFS= read -r key; do
  prefix="${key%%/*}"; version="${key#*/}"
  # shellcheck disable=SC2012
  present="$(ls "$work/g/$key" | sort | tr '\n' ' ' | sed 's/ *$//')"
  n="$(ls "$work/g/$key" | wc -l | tr -d ' ')"
  if [ "$n" -lt 2 ]; then
    # One triple in hand proves nothing. This is the normal shape when a sibling
    # build failed (the release publishes what did build) or when only one triple
    # was rebuilt — say so rather than reporting a false pass.
    echo "  skip  $prefix $version — only $n triple ($present)"
    echo "| \`$prefix $version\` | $n | not comparable |" >> "$summary"
    continue
  fi
  # Report per PATH, not per pair: for every path any triple ships, list who has
  # it and who doesn't. A pairwise diff would label auth_parsec.so "only in
  # aarch64-apple-darwin" when aarch64 Linux ships it too — the reader needs the
  # whole picture to tell "one triple is missing it" from "one triple added it".
  #
  # comm against the union (rather than grepping each path in each listing) keeps
  # this linear: the weekly sweep compares ~100 versions of ~1500 paths each.
  # shellcheck disable=SC2012
  triples="$(ls "$work/g/$key" | sort)"
  shorts=""
  cat "$work/g/$key"/* | sort -u > "$work/union"
  : > "$work/missing"
  for t in $triples; do
    short="$(echo "$t" | sed -e 's|-unknown-linux-gnu$|-linux|' -e 's|-apple-darwin$|-darwin|')"
    shorts="$shorts $short"
    comm -23 "$work/union" "$work/g/$key/$t" | sed "s|^|$short\t|"
  done > "$work/missing"
  count="$(cut -f2 "$work/missing" | sort -u | grep -c '^' || true)"
  diffs=""
  if [ "$count" != "0" ]; then
    diffs="$(sort -t"$(printf '\t')" -k2,2 "$work/missing" | awk -F'\t' -v all="$shorts" '
      function flush(   i, n, A, have) {
        if (cur == "") return
        n = split(all, A, " "); have = ""
        for (i = 1; i <= n; i++)
          if (index(m " ", " " A[i] " ") == 0) have = have " " A[i]
        printf "    %s\n        present:%s   MISSING:%s\n", cur, (have == "" ? " (none)" : have), m
      }
      { if ($2 != cur) { flush(); cur = $2; m = "" } m = m " " $1 }
      END { flush() }')"
  fi

  if [ -z "$diffs" ]; then
    echo "  ok    $prefix $version — $n triples ship the same tree"
    echo "| \`$prefix $version\` | $n | ok |" >> "$summary"
    continue
  fi
  if waived "$prefix" "$version"; then
    nwaived=$((nwaived + 1))
    echo "  known $prefix $version — $count differing paths (waived: already published)"
    echo "$diffs" | sed 's/^/  /'
    echo "| \`$prefix $version\` | $n | $count differing paths (waived) |" >> "$summary"
    continue
  fi
  bad=1
  echo "::error::$prefix $version — triples ship different trees ($count differing paths)"
  echo "  FAIL  $prefix $version — $count differing paths"
  echo "$diffs" | sed 's/^/  /'
  echo "| \`$prefix $version\` | $n | **$count differing paths** |" >> "$summary"
done < "$groups"

echo "" >> "$summary"
if [ "$bad" = 0 ]; then
  if [ "$nwaived" = 0 ]; then
    echo "parity OK"
    echo "**All comparable artifacts agree across triples.**" >> "$summary"
  else
    echo "parity OK ($nwaived waived divergence(s) — see scripts/parity-waivers.txt)"
    echo "**No new divergence.** $nwaived artifact(s) diverge as already published (waived)." >> "$summary"
  fi
  exit 0
fi
cat >> "$summary" <<'EOF'
**Triples disagree.** A version must ship the same tree everywhere: a plugin or
tool present on one architecture and absent on another turns a working config
into an arch-dependent failure. Fix the recipe, or — if the artifacts are already
published and therefore immutable — declare it in `scripts/parity-waivers.txt`.
EOF
echo "parity FAILED: see above"
exit 1
