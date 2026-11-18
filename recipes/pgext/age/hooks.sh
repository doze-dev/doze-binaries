# shellcheck shell=bash

# Apache AGE generates its Cypher parser with bison (>= 3), flex and perl at build
# time. The Postgres tree's Makefile.global names whatever its build host had
# (macOS: /usr/bin/bison, 2.3, too old for AGE's grammar), so the build is told
# which to use. Build tools only: nothing of them ships.
pgext_hook_deps() {
  local triple="$1" bison
  case "$triple" in
    *linux*)
      [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || sudo apt-get install -y bison flex
      bison="$(command -v bison)"
      ;;
    *darwin*)
      [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || brew install bison flex || true
      bison="$(brew --prefix bison)/bin/bison"
      ;;
  esac
  [ -x "$bison" ] || pgext_die "age needs bison >= 3 (not found)"
  # PERL too: the tree records the build host's (/opt/homebrew/bin/perl).
  PGEXT_MAKE_ARGS+=("BISON=$bison" "FLEX=$(command -v flex)" "PERL=$(command -v perl)")
}

# AGE 1.8 (PG18) runs bison with -Werror, and bison 3.8 reports the grammar's
# old-style directives (%name-prefix, %pure-parser) as deprecated: with
# -Werror that fails the build on every bison 3.8 host. The warning is only
# about spelling, so it is switched off (YFLAGS feeds BISONFLAGS in PGXS).
PGEXT_MAKE_ARGS+=("YFLAGS=-Wno-deprecated")
