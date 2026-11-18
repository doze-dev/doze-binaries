# shellcheck shell=bash

# The bundle builds with --no-default-features (so only the one pg<major>
# feature is on); build_parallel is the other default upstream ships with
# (parallel DiskANN index builds), so it is put back.
PGEXT_PGRX_FEATURES="build_parallel"
