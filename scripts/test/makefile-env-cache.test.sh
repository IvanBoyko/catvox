#!/usr/bin/env bash
# Tests for the Makefile xcconfig env-cache rule. Covers the cache-key
# derivation so overriding CATVOX_ENV_CONFIG never reads a stale fragment
# built from a different file path.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 1

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$repo_root/.make.d"' EXIT

# Snapshot Makefile is built once and reused across cases.
snapshot_mk="${tmpdir}/snapshot-vars.mk"
cat > "$snapshot_mk" <<'EOF'
.PHONY: snapshot
snapshot:
	@printf 'GCP_PROJECT_ID=%s\n' '$(GCP_PROJECT_ID)'
	@printf 'CATVOX_FUNCTION_REGION=%s\n' '$(CATVOX_FUNCTION_REGION)'
EOF

pass=0
fail=0
failed_cases=()

note() { printf '  %s\n' "$*"; }

# Portable mtime in seconds since epoch. GNU `stat -f` exists but means
# something completely different (filesystem info) and exits 0, so the naive
# `stat -f '%m' || stat -c '%Y'` chain never falls through on Linux. Branch
# on `uname` to pick the right invocation up front.
mtime_epoch() {
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

run_case() {
  local name="$1"
  rm -rf "${repo_root}/.make.d"
  if "case_${name}"; then
    pass=$((pass + 1))
    printf '  ok  %s\n' "$name"
  else
    fail=$((fail + 1))
    failed_cases+=("$name")
    printf '  FAIL %s\n' "$name"
  fi
}

# Default config path → cache filename derived from the path.
case_cache_filename_encodes_default_path() {
  make -f Makefile -f "$snapshot_mk" snapshot > /dev/null 2>&1
  local expected="config__environments__dev.xcconfig.env.mk"
  if [[ ! -f ".make.d/${expected}" ]]; then
    note "expected .make.d/${expected}, got: $(ls .make.d/ 2>/dev/null)"
    return 1
  fi
}

# Different config paths must produce different cache files. This is the
# F1 regression test: a stale `dev` cache must not satisfy a request that
# overrides CATVOX_ENV_CONFIG to a different file.
case_distinct_cache_per_config_path() {
  # Step 1: build the default-path cache.
  make -f Makefile -f "$snapshot_mk" snapshot > /dev/null 2>&1
  local default_cache="config__environments__dev.xcconfig.env.mk"

  # Step 2: prepare a deliberately wrong override config with an older mtime
  # so a mtime-only check would mistakenly think the cache is fresh enough.
  local override="${tmpdir}/staging-fake.xcconfig"
  printf 'GCP_PROJECT_ID = wrong-project-id\nCATVOX_FUNCTION_REGION = europe-west1\n' > "$override"
  touch -t 202001010000 "$override"

  # Step 3: invoke with the override.
  local out
  out="$(make -f Makefile -f "$snapshot_mk" "CATVOX_ENV_CONFIG=$override" snapshot 2>/dev/null)" || return 1

  # Step 4: assert the override values won, not the dev cache.
  if [[ "$out" != *"GCP_PROJECT_ID=wrong-project-id"* ]]; then
    note "override config was ignored; got:"
    note "$out"
    return 1
  fi
  if [[ "$out" != *"CATVOX_FUNCTION_REGION=europe-west1"* ]]; then
    note "override config was ignored for CATVOX_FUNCTION_REGION; got:"
    note "$out"
    return 1
  fi

  # Step 5: assert both cache files coexist.
  if [[ ! -f ".make.d/${default_cache}" ]]; then
    note "expected default cache .make.d/${default_cache} to remain"
    return 1
  fi
  local found=0
  for entry in .make.d/*staging-fake.xcconfig.env.mk; do
    [[ -e "$entry" ]] && found=1
  done
  if [[ "$found" -ne 1 ]]; then
    note "expected an override-path cache file under .make.d/; got: $(echo .make.d/*)"
    return 1
  fi
}

# Cache hit: second invocation against the same config does not rebuild.
case_cache_hit_on_repeat() {
  make -f Makefile -f "$snapshot_mk" snapshot > /dev/null 2>&1
  local cache=".make.d/config__environments__dev.xcconfig.env.mk"
  local mtime1
  mtime1=$(mtime_epoch "$cache")
  sleep 1
  make -f Makefile -f "$snapshot_mk" snapshot > /dev/null 2>&1
  local mtime2
  mtime2=$(mtime_epoch "$cache")
  if [[ "$mtime1" != "$mtime2" ]]; then
    note "cache file mtime changed: $mtime1 -> $mtime2 (expected no rebuild)"
    return 1
  fi
}

# Touching xcconfig invalidates the cache.
case_cache_invalidates_on_xcconfig_touch() {
  make -f Makefile -f "$snapshot_mk" snapshot > /dev/null 2>&1
  local cache=".make.d/config__environments__dev.xcconfig.env.mk"
  local mtime1
  mtime1=$(mtime_epoch "$cache")
  sleep 1
  touch config/environments/dev.xcconfig
  make -f Makefile -f "$snapshot_mk" snapshot > /dev/null 2>&1
  local mtime2
  mtime2=$(mtime_epoch "$cache")
  if [[ "$mtime1" == "$mtime2" ]]; then
    note "cache file mtime unchanged after touching xcconfig"
    return 1
  fi
}

printf 'makefile env-cache tests\n'
run_case cache_filename_encodes_default_path
run_case distinct_cache_per_config_path
run_case cache_hit_on_repeat
run_case cache_invalidates_on_xcconfig_touch

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then
  printf 'failed: %s\n' "${failed_cases[*]}"
  exit 1
fi
