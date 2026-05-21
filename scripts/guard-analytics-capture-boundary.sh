#!/usr/bin/env bash
set -euo pipefail

allowed_source='CatVox/Services/AnalyticsService.swift'
app_source_path='CatVox'
swift_import_pattern='^[[:space:]]*(@[_[:alpha:]][_[:alnum:]]*(\([^)]*\))?[[:space:]]+)*import[[:space:]]+((class|struct|enum|protocol|typealias|func|let|var)[[:space:]]+)?PostHog([.[:space:]]|$)'
pattern="(${swift_import_pattern}|PostHogSDK\\.shared)"

# This guard is intentionally scoped to app source; tests may import helpers freely.
set +e
matches="$(git grep -n -E "${pattern}" -- "${app_source_path}" ":!${allowed_source}")"
grep_status=$?
set -e

if [[ "${grep_status}" -gt 1 ]]; then
  printf 'Analytics capture boundary guard failed while scanning app source. git grep exited with %s.\n' "${grep_status}" >&2
  exit "${grep_status}"
fi

if [[ -n "${matches}" ]]; then
  printf '%s\n' 'PostHog SDK usage must stay behind AnalyticsService.'
  printf 'Allowed source: %s\n\n' "${allowed_source}"
  printf '%s\n' "${matches}"
  exit 1
fi

printf '%s\n' 'Analytics capture boundary guard passed.'
