#!/usr/bin/env node
// Discover the Firebase iOS app id for a given bundle id.
//
// Reads `firebase apps:list IOS --json` output on stdin and prints the appId of
// the iOS app whose bundle id (Firebase reports it as "bundleId" or "namespace")
// matches the single CLI argument. Prints nothing when there is no exact match
// or the input is not parseable.
//
// Kept as a pure stdin->stdout filter so it is unit-testable without invoking the
// Firebase CLI. Used by scripts/import-preexisting-resources.sh to discover a
// pre-existing app for idempotent `terraform import` (issue #38 Step 3, S5).

import process from "node:process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BUNDLE_FIELDS = ["bundleId", "namespace"];

// Match by exact bundle id, never substring: `com.kathelix.catvox` is a prefix
// of `com.kathelix.catvox.dev`, so a loose match would cross environments
// (see AGENTS.md § Config / Infrastructure Change Workflow).
export function findIosAppId(jsonText, bundleId) {
  const target = String(bundleId ?? "").trim();
  if (target === "") return "";

  let parsed;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    return "";
  }

  const apps = Array.isArray(parsed)
    ? parsed
    : Array.isArray(parsed?.result)
      ? parsed.result
      : Array.isArray(parsed?.apps)
        ? parsed.apps
        : [];

  for (const app of apps) {
    if (!app || typeof app !== "object") continue;
    const bundle = BUNDLE_FIELDS.map((field) => app[field]).find(
      (value) => typeof value === "string" && value.trim() !== "",
    );
    if (bundle && bundle.trim() === target && typeof app.appId === "string") {
      return app.appId.trim();
    }
  }
  return "";
}

async function readStdin() {
  let raw = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) raw += chunk;
  return raw;
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const appId = findIosAppId(await readStdin(), process.argv[2] ?? "");
  if (appId) process.stdout.write(appId);
}
