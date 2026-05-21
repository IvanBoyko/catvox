#!/usr/bin/env bash
set -euo pipefail

allowed_source='CatVox/Services/AnalyticsService.swift'
pattern='(^[[:space:]]*import[[:space:]]+PostHog[[:space:]]*$|PostHogSDK\.shared)'

matches="$(git grep -n -E "${pattern}" -- CatVox ":!${allowed_source}" || true)"

if [[ -n "${matches}" ]]; then
  printf '%s\n' 'PostHog SDK usage must stay behind AnalyticsService.'
  printf 'Allowed source: %s\n\n' "${allowed_source}"
  printf '%s\n' "${matches}"
  exit 1
fi

printf '%s\n' 'Analytics capture boundary guard passed.'
