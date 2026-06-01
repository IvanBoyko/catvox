#!/usr/bin/env node
// Release-safety validator for the protected environment (issue #38, Step 5).
//
// Mechanizes the "Release/App Store archive" leak checks that were previously
// only manual operator steps in docs/SMOKE_CHECKLIST.md. It is environment-
// agnostic: it validates "the protected environment" (the one whose
// CATVOX_ENVIRONMENT_PROTECTED=true) and scans generically for ANY OTHER
// committed environment's identifiers — no hard-coded environment names.
//
// Layered on top of validate-environment-config.mjs (reused, not duplicated),
// it additionally asserts that the configuration a Release build embeds:
//   - is live-complete (no leftover placeholders) and protected-tier postured
//   - carries no other environment's project id, bundle id, Firebase app id, or
//     backend endpoint host — including the composed https:// Info.plist URLs
//   - sets no App Check debug-token key (mutable-tier only)
//   - uses the production App Attest entitlement
//   - keeps the Swift debug surfaces (debug App Check provider, debug-token
//     bootstrap, dev fallback endpoints) behind #if DEBUG
//   - is the configuration an archive actually selects: project.yml binds the
//     Release configuration to the protected tier and every scheme archives
//     with Release
//
// The only literals here are generic key names, file paths, and enum values.
// Literal environment names belong only in the CI/CD promotion pipeline.

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  validateEnvironmentConfig,
  readXcconfigValues,
  normalize,
} from './validate-environment-config.mjs';
import placeholderHelpers from './lib/config-placeholders.cjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { isPlaceholder } = placeholderHelpers;

// Keys that must never carry a value in a protected Release config. The Firebase
// debug provider reads these at launch in mutable builds; in a protected Release
// they must be absent. Mirrors AppCheckDebugTokenBootstrap's env-var names and
// the manual SMOKE_CHECKLIST item forbidding TF_VAR_APP_CHECK_DEBUG_TOKEN.
const debugTokenKeys = [
  'TF_VAR_APP_CHECK_DEBUG_TOKEN',
  'CATVOX_APP_CHECK_DEBUG_TOKEN',
  'APP_CHECK_DEBUG_TOKEN',
  'AppCheckDebugToken',
  'FIRAAppCheckDebugToken',
  'FIRDebugEnabled',
];

export function validateReleaseSafety({
  configPath,
  environmentName,
  root = repoRoot,
  entitlementsPath,
} = {}) {
  const errors = [];
  const absConfig = resolve(configPath);

  // (a) Reuse the full structural validator with requireLive=true. This rejects
  // any remaining placeholder and re-confirms the protected-tier invariants
  // (App Check ENFORCED, WIF ref pinned, ABANDON deletion, absent from the
  // integration-safe list). Fold its line-per-error message into ours.
  try {
    validateEnvironmentConfig({ configPath: absConfig, environmentName, requireLive: true });
  } catch (err) {
    for (const line of String(err instanceof Error ? err.message : err).split('\n')) {
      pushError(errors, line);
    }
  }

  const values = readXcconfigValues(absConfig);
  const env = environmentName || normalize(values.get('CATVOX_ENVIRONMENT'));

  const projectYmlPath = join(root, 'project.yml');
  const projectSpec = readFileOrNull(projectYmlPath);
  if (projectSpec == null) {
    pushError(errors, `Could not read ${projectYmlPath}`);
  }
  // The archive's Info.plist is generated from project.yml's info.properties
  // (with $(...) resolved against the xcconfig). Resolve it once; several checks
  // scan this surface, not just the xcconfig.
  const infoValues = resolveInfoPlistValues(projectSpec, values);

  assertProtectedPosture(values, env, errors);
  assertNoDebugTokenKeys(values, infoValues, errors);
  assertAppAttestEntitlement(
    resolveEntitlementsPath({ explicit: entitlementsPath, projectSpec, root, errors }),
    errors
  );
  assertNoForeignIdentifiers(values, infoValues, absConfig, errors);
  assertRequiredInfoPlistKeys(infoValues, projectSpec, errors);
  assertDebugSurfacesGated(root, errors);
  assertArchiveBinding(projectSpec, root, errors);

  const deduped = [...new Set(errors)];
  if (deduped.length > 0) {
    throw new Error(deduped.join('\n'));
  }

  return { configPath: absConfig, environmentName: env, isProtected: true };
}

function pushError(errors, message) {
  const trimmed = normalize(message);
  if (trimmed) {
    errors.push(trimmed);
  }
}

// (b) The validator only makes sense for the protected tier.
function assertProtectedPosture(values, env, errors) {
  if (normalize(values.get('CATVOX_ENVIRONMENT_PROTECTED')) !== 'true') {
    pushError(
      errors,
      `release-safety validates the protected environment, but ${env || 'this config'} is not protected (CATVOX_ENVIRONMENT_PROTECTED must be true)`
    );
  }
}

// (d) No App Check debug-token key may be set in a protected Release config.
function assertNoDebugTokenKeys(values, infoValues, errors) {
  for (const key of debugTokenKeys) {
    if (normalize(values.get(key))) {
      pushError(
        errors,
        `${key} must not be set in a protected Release config (App Check debug tokens are mutable-tier only)`
      );
    }
  }
  // The archive's Info.plist is generated from project.yml's info.properties, so
  // a debug-token key or a leftover provisioning placeholder hard-coded there
  // ships in the Release build too — the xcconfig is not the only surface.
  const debugTokenKeySet = new Set(debugTokenKeys);
  for (const [key, value] of infoValues) {
    const resolved = normalize(value);
    if (!resolved) {
      continue;
    }
    if (debugTokenKeySet.has(key)) {
      pushError(
        errors,
        `Info.plist key ${key} must not be set in a protected Release build (App Check debug tokens are mutable-tier only)`
      );
    }
    if (isProvisioningPlaceholder(resolved)) {
      pushError(errors, `Info.plist value for ${key} must not be a leftover placeholder (${resolved})`);
    }
  }
}

function isProvisioningPlaceholder(value) {
  const lower = value.toLowerCase();
  return lower.includes('replace-with') || lower.includes('placeholder') || lower === 'todo';
}

// Info.plist keys a Release build requires at launch: CatVoxAppConfiguration reads
// them, and in Release a missing key fatals while an unresolved $(...) ships as a
// broken endpoint. CatVoxPostHogProjectToken is intentionally optional (analytics
// disables gracefully), so it is not listed.
const requiredInfoPlistKeys = [
  'CatVoxEnvironment',
  'CatVoxSignedUploadURLEndpoint',
  'CatVoxAnalyseVideoEndpoint',
  'CatVoxPostHogHost',
];

// (h) The generated Info.plist must actually contain the required runtime keys,
// fully resolved. Scanning for bad content is not enough: a dropped key or an
// unresolved $(...) substitution would fatal the Release app or ship a broken URL.
function assertRequiredInfoPlistKeys(infoValues, projectSpec, errors) {
  if (projectSpec == null) {
    return; // project.yml read error already reported
  }
  const present = new Map(infoValues.map(([key, value]) => [key, normalize(value)]));
  for (const key of requiredInfoPlistKeys) {
    const value = present.get(key);
    if (!value) {
      pushError(
        errors,
        `Info.plist must define ${key}; a Release build requires it (set it in project.yml info.properties)`
      );
      continue;
    }
    if (value.includes('$(')) {
      pushError(
        errors,
        `Info.plist value for ${key} has an unresolved substitution (${value}); it must resolve to a concrete value`
      );
    }
  }
}

// The entitlements file the Release build actually signs with is whatever
// project.yml binds to CODE_SIGN_ENTITLEMENTS — not a hard-coded path. Resolving
// it from the spec means dropping or repointing that setting is caught, instead
// of validating a file the build no longer uses. Tests may pass an explicit path.
function resolveEntitlementsPath({ explicit, projectSpec, root, errors }) {
  if (explicit) {
    return explicit;
  }
  if (projectSpec == null) {
    return null; // project.yml read error already reported
  }
  const relative = effectiveReleaseEntitlements(projectSpec);
  if (!relative) {
    pushError(
      errors,
      'project.yml must set CODE_SIGN_ENTITLEMENTS for the app target (in base or the Release config) so the Release build signs with the committed entitlements'
    );
    return null;
  }
  return join(root, relative);
}

// (e) The entitlements the Release build signs with must select the production
// App Attest environment, never the development attestation service.
function assertAppAttestEntitlement(entitlementsPath, errors) {
  if (!entitlementsPath) {
    return; // resolution failed; the specific error was already reported
  }
  const xml = readFileOrNull(entitlementsPath);
  if (xml == null) {
    pushError(errors, `Could not read entitlements file: ${entitlementsPath}`);
    return;
  }
  const match = xml.match(
    /com\.apple\.developer\.devicecheck\.appattest-environment<\/key>\s*<string>([^<]*)<\/string>/
  );
  const value = match ? match[1].trim() : null;
  if (value !== 'production') {
    pushError(
      errors,
      'CatVox/CatVox.entitlements must set com.apple.developer.devicecheck.appattest-environment to production for Release'
    );
  }
}

// The Info.plist the archive embeds is generated from project.yml's
// info.properties, with $(...) references resolved against the xcconfig. Return
// those resolved values so a foreign identifier hard-coded directly in
// info.properties — not only one reached through the xcconfig — is scanned.
function resolveInfoPlistValues(projectSpec, values) {
  if (projectSpec == null) {
    return [];
  }
  let parsed;
  try {
    parsed = parseProjectYaml(projectSpec);
  } catch {
    return [];
  }
  const properties = parsed?.targets?.CatVox?.info?.properties;
  if (!properties || typeof properties !== 'object' || Array.isArray(properties)) {
    return [];
  }
  const resolved = [];
  for (const [key, raw] of Object.entries(properties)) {
    if (typeof raw !== 'string') {
      continue;
    }
    const value = raw.replace(/\$\(([A-Za-z_][A-Za-z0-9_]*)\)/g, (match, name) => {
      const resolvedRef = normalize(values.get(name));
      return resolvedRef != null ? resolvedRef : match;
    });
    resolved.push([key, value]);
  }
  return resolved;
}

// (c) The heart of the leak check: no value the Release build embeds may
// reference another committed environment. Project ids match as substrings
// (they appear inside derived bucket / service-account / app-id strings);
// bundle ids match exactly (so a longer bundle that merely shares a prefix is
// not flagged); Firebase app ids, API keys, endpoint hosts, and the PostHog
// token match as substrings; the PostHog project id matches exactly. The scan
// surface is every xcconfig value plus the generated Info.plist values.
function assertNoForeignIdentifiers(values, infoValues, configPath, errors) {
  const foreign = collectForeignReleaseIdentifiers(configPath);

  const scan = [
    ...values.entries(),
    ...infoValues.map(([key, value]) => [`Info.plist:${key}`, value]),
  ];

  for (const [key, value] of scan) {
    for (const projectId of foreign.projectIds) {
      if (value.includes(projectId)) {
        pushError(errors, `${key} must not reference another environment's project (${projectId})`);
      }
    }
    if (foreign.bundleIds.has(value)) {
      pushError(errors, `${key} must not reference another environment's bundle id (${value})`);
    }
    for (const appId of foreign.firebaseAppIds) {
      if (value.includes(appId)) {
        pushError(
          errors,
          `${key} must not reference another environment's Firebase app id (${appId})`
        );
      }
    }
    for (const apiKey of foreign.firebaseApiKeys) {
      if (value.includes(apiKey)) {
        pushError(
          errors,
          `${key} must not reference another environment's Firebase API key (${apiKey})`
        );
      }
    }
    for (const host of foreign.endpointHosts) {
      if (value.includes(host)) {
        pushError(
          errors,
          `${key} must not reference another environment's endpoint host (${host})`
        );
      }
    }
    for (const token of foreign.posthogTokens) {
      if (value.includes(token)) {
        pushError(
          errors,
          `${key} must not reference another environment's PostHog project token (${token})`
        );
      }
    }
    if (foreign.posthogProjectIds.has(value)) {
      pushError(errors, `${key} must not reference another environment's PostHog project id (${value})`);
    }
  }
}

// Gather every OTHER committed environment's app-visible, environment-unique
// identifiers, so a value that would ship in the Release artifact can be checked
// against them. Covers what the app embeds: project id, bundle id, Firebase app
// id and API key, backend endpoint hosts, and the PostHog project token and id.
// Deliberately excluded: identifiers shared across environments by design (the
// PostHog host and organization id), and CI-only identity that never ships in
// the app (WIF provider, service account), which the base config validator
// already checks. Placeholders and unparseable siblings are skipped.
export function collectForeignReleaseIdentifiers(configPath) {
  const absolute = resolve(configPath);
  const dir = dirname(absolute);
  const self = basename(absolute);
  const projectIds = new Set();
  const bundleIds = new Set();
  const firebaseAppIds = new Set();
  const firebaseApiKeys = new Set();
  const endpointHosts = new Set();
  const posthogTokens = new Set();
  const posthogProjectIds = new Set();
  const collected = {
    projectIds,
    bundleIds,
    firebaseAppIds,
    firebaseApiKeys,
    endpointHosts,
    posthogTokens,
    posthogProjectIds,
  };

  let entries = [];
  try {
    entries = readdirSync(dir).filter((name) => name.endsWith('.xcconfig') && name !== self);
  } catch {
    return collected;
  }

  for (const entry of entries) {
    let values;
    try {
      values = readXcconfigValues(join(dir, entry));
    } catch {
      continue;
    }
    addIfReal(projectIds, values.get('CATVOX_PROJECT_ID'));
    addIfReal(bundleIds, values.get('CATVOX_IOS_BUNDLE_ID'));
    addIfReal(firebaseAppIds, values.get('CATVOX_FIREBASE_APP_ID'));
    addIfReal(firebaseApiKeys, values.get('CATVOX_FIREBASE_API_KEY'));
    addIfReal(endpointHosts, values.get('CATVOX_SIGNED_UPLOAD_URL_HOST'));
    addIfReal(endpointHosts, values.get('CATVOX_ANALYSE_VIDEO_HOST'));
    // PostHog: only the per-project token and id are environment-unique and ship
    // in the app (project.yml embeds the token as CatVoxPostHogProjectToken). The
    // PostHog host and organization id are deliberately shared across
    // environments, so they are not treated as foreign (ADR-0019, ADR-0020).
    addIfReal(posthogTokens, values.get('CATVOX_POSTHOG_PROJECT_TOKEN'));
    addIfReal(posthogProjectIds, values.get('CATVOX_POSTHOG_PROJECT_ID'));
  }
  return collected;
}

function addIfReal(set, raw) {
  const value = normalize(raw);
  if (value && !isPlaceholder(value)) {
    set.add(value);
  }
}

// (f) The Swift debug surfaces must stay behind #if DEBUG so they cannot compile
// into a Release build, and the Release branch must keep its production
// guarantees (App Attest only, debug defaults disallowed). Positive + negative
// assertions: it fails both when a debug symbol escapes its guard and when a
// Release-branch guarantee is removed.
export function assertDebugSurfacesGated(root, errors) {
  const appPath = join(root, 'CatVox/App/CatVoxApp.swift');
  const bootstrapPath = join(root, 'CatVox/App/AppCheckDebugTokenBootstrap.swift');
  const configPath = join(root, 'CatVox/App/CatVoxAppConfiguration.swift');

  const app = readFileOrNull(appPath);
  if (app == null) {
    pushError(errors, `Could not read ${appPath}`);
  } else {
    const lines = classifyDebugRegions(app);
    for (const line of lines) {
      if (line.directive) continue;
      if (line.text.includes('AppCheckDebugProviderFactory') && !line.debugOnly) {
        pushError(errors, 'AppCheckDebugProviderFactory must stay inside #if DEBUG in CatVox/App/CatVoxApp.swift');
      }
      if (line.text.includes('AppCheckDebugTokenBootstrap') && !line.debugOnly) {
        pushError(errors, 'AppCheckDebugTokenBootstrap must only be referenced inside #if DEBUG in CatVox/App/CatVoxApp.swift');
      }
    }
    // Assert the Release (#else) branch itself selects the production factory,
    // via the classified regions — not a whole-file string match that a stray
    // occurrence elsewhere could satisfy.
    const releaseSelectsProductionFactory = lines.some(
      (line) =>
        !line.directive &&
        line.releaseOfDebug &&
        /CatVoxAppCheckProviderFactory\s*\(\s*\)/.test(line.text)
    );
    if (!releaseSelectsProductionFactory) {
      pushError(errors, 'The Release (#else) branch in CatVox/App/CatVoxApp.swift must select the production App Check provider factory (CatVoxAppCheckProviderFactory())');
    }
    // ...and that factory must build an App Attest provider (scoped to its type
    // body, so the assertion tracks the actual provider, not any string).
    if (!typeBodyContains(app, 'CatVoxAppCheckProviderFactory', /AppAttestProvider\s*\(/)) {
      pushError(errors, 'CatVoxAppCheckProviderFactory must instantiate AppAttestProvider (the production App Check provider)');
    }
  }

  const bootstrap = readFileOrNull(bootstrapPath);
  if (bootstrap == null) {
    pushError(errors, `Could not read ${bootstrapPath}`);
  } else {
    const lines = classifyDebugRegions(bootstrap);
    const declaration = lines.find(
      (line) => !line.directive && /\benum\s+AppCheckDebugTokenBootstrap\b/.test(line.text)
    );
    if (!declaration) {
      pushError(errors, 'Could not find the AppCheckDebugTokenBootstrap declaration to verify #if DEBUG gating');
    } else if (!declaration.debugOnly) {
      pushError(errors, 'AppCheckDebugTokenBootstrap must be defined inside #if DEBUG');
    }
  }

  const config = readFileOrNull(configPath);
  if (config == null) {
    pushError(errors, `Could not read ${configPath}`);
  } else {
    const lines = classifyDebugRegions(config);
    for (const line of lines) {
      if (line.directive) continue;
      if (line.text.includes('debugDefault') && !line.debugOnly) {
        pushError(errors, 'Dev fallback endpoints (debugDefault*) must stay inside #if DEBUG in CatVox/App/CatVoxAppConfiguration.swift');
      }
    }
    if (!accessorReleaseBranchReturnsFalse(lines, 'runtimeAllowsDebugDefaults')) {
      pushError(errors, 'runtimeAllowsDebugDefaults must return false in its #else (Release) branch in CatVox/App/CatVoxAppConfiguration.swift');
    }
  }
}

// Classify each source line by whether it compiles only in DEBUG. Supports the
// directive subset used in this repo (#if DEBUG / #else / #endif; no #elseif and
// no `#if !DEBUG`). A line is debug-only when some enclosing conditional frame
// is an `#if DEBUG` whose active branch is still the truthy (#if) branch.
export function classifyDebugRegions(source) {
  const stack = [];
  return source.split(/\r?\n/).map((text) => {
    const trimmed = text.trim();
    let directive = null;
    if (/^#if(\s|$)/.test(trimmed)) {
      const condition = trimmed.replace(/^#if\s*/, '');
      stack.push({ isDebugIf: /^DEBUG\b/.test(condition), inElse: false });
      directive = 'if';
    } else if (/^#elseif(\s|$)/.test(trimmed)) {
      if (stack.length > 0) {
        stack[stack.length - 1].isDebugIf = false;
        stack[stack.length - 1].inElse = true;
      }
      directive = 'elseif';
    } else if (/^#else\b/.test(trimmed)) {
      if (stack.length > 0) {
        stack[stack.length - 1].inElse = true;
      }
      directive = 'else';
    } else if (/^#endif\b/.test(trimmed)) {
      stack.pop();
      directive = 'endif';
    }
    const debugOnly = stack.some((frame) => frame.isDebugIf && !frame.inElse);
    // The Release branch of a `#if DEBUG`: inside its `#else`, and not nested
    // under any still-truthy DEBUG frame.
    const releaseOfDebug = !debugOnly && stack.some((frame) => frame.isDebugIf && frame.inElse);
    return { text, trimmed, directive, debugOnly, releaseOfDebug };
  });
}

// True when the brace-balanced body of the named Swift type matches pattern.
// Scopes a check to one declaration instead of the whole file, so a matching
// string elsewhere cannot satisfy it.
function typeBodyContains(source, typeName, pattern) {
  const declaration = new RegExp(`\\b(?:class|struct|enum|extension)\\s+${typeName}\\b`).exec(source);
  if (!declaration) {
    return false;
  }
  const open = source.indexOf('{', declaration.index);
  if (open === -1) {
    return false;
  }
  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === '{') {
      depth += 1;
    } else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) {
        return pattern.test(source.slice(open + 1, i));
      }
    }
  }
  return false;
}

// Within the named computed property, assert the non-DEBUG branch returns false.
function accessorReleaseBranchReturnsFalse(lines, accessorName) {
  const start = lines.findIndex(
    (line) => !line.directive && /\bvar\b/.test(line.text) && line.text.includes(accessorName)
  );
  if (start === -1) {
    return false;
  }
  for (let i = start + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.directive) continue;
    if (/\b(var|func)\b/.test(line.text)) break; // next member; stop scanning
    if (/return\s+false\b/.test(line.text) && !line.debugOnly) {
      return true;
    }
  }
  return false;
}

// Minimal block-YAML reader — enough of YAML to navigate the xcodegen project
// spec structurally (nested maps, scalars, lists, `#` comments, optional quotes)
// instead of by brittle first-match regex. Constructs project.yml does not use —
// flow syntax, anchors, multi-line scalars — are not modeled. Map/scalar lookups
// are exact; list items are collected so they never corrupt a sibling map.
export function parseProjectYaml(text) {
  const root = {};
  const stack = [{ indent: -1, container: root }];
  for (const rawLine of text.split(/\r?\n/)) {
    const line = stripInlineComment(rawLine);
    if (line.trim() === '') {
      continue;
    }
    const indent = line.length - line.trimStart().length;
    const content = line.trim();
    while (stack.length > 1 && indent <= stack[stack.length - 1].indent) {
      stack.pop();
    }
    const frame = stack[stack.length - 1];
    if (frame.container == null) {
      // Realize a pending child now that its kind (map vs list) is known.
      frame.container = content.startsWith('- ') ? [] : {};
      frame.parent[frame.parentKey] = frame.container;
    }
    const container = frame.container;

    if (content.startsWith('- ')) {
      if (!Array.isArray(container)) {
        continue;
      }
      const itemText = content.slice(2).trim();
      const colon = itemText.indexOf(':');
      if (colon === -1) {
        container.push(unquote(itemText));
      } else {
        container.push({
          [unquote(itemText.slice(0, colon).trim())]: unquote(itemText.slice(colon + 1).trim()),
        });
      }
      continue;
    }

    if (Array.isArray(container)) {
      continue;
    }
    const colon = content.indexOf(':');
    if (colon === -1) {
      continue;
    }
    const key = unquote(content.slice(0, colon).trim());
    const rest = content.slice(colon + 1).trim();
    if (rest === '') {
      stack.push({ indent, container: null, parent: container, parentKey: key });
    } else {
      container[key] = unquote(rest);
    }
  }
  return root;
}

function stripInlineComment(line) {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (ch === '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (ch === '#' && !inSingle && !inDouble && (i === 0 || /\s/.test(line[i - 1]))) {
      return line.slice(0, i);
    }
  }
  return line;
}

function unquote(value) {
  const trimmed = value.trim();
  if (
    trimmed.length >= 2 &&
    ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'")))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

// The Release build's effective CODE_SIGN_ENTITLEMENTS for the app target: a
// Release config-specific override wins over the target base, which wins over a
// flat settings value (mirrors xcodegen precedence). Undefined when none is set.
function effectiveReleaseEntitlements(projectSpec) {
  let parsed;
  try {
    parsed = parseProjectYaml(projectSpec);
  } catch {
    return undefined;
  }
  const settings = parsed?.targets?.CatVox?.settings;
  if (!settings || typeof settings !== 'object') {
    return undefined;
  }
  const candidates = [
    settings.configs?.Release?.CODE_SIGN_ENTITLEMENTS,
    settings.base?.CODE_SIGN_ENTITLEMENTS,
    settings.CODE_SIGN_ENTITLEMENTS,
  ];
  return candidates.find((value) => typeof value === 'string' && value.length > 0);
}

// (g) project.yml must bind the Release configuration to the protected tier and
// the Debug configuration to a mutable tier, and every scheme must archive with
// Release. Resolved through the configs themselves, so no environment is named.
export function assertArchiveBinding(spec, root, errors) {
  if (spec == null) {
    return; // project.yml read error already reported
  }
  let parsed;
  try {
    parsed = parseProjectYaml(spec);
  } catch {
    pushError(errors, 'project.yml could not be parsed for the archive-selection check');
    return;
  }

  const configFiles = parsed?.targets?.CatVox?.configFiles;
  const releaseConfig = typeof configFiles?.Release === 'string' ? configFiles.Release : undefined;
  const debugConfig = typeof configFiles?.Debug === 'string' ? configFiles.Debug : undefined;
  assertBindingTier(root, releaseConfig, 'Release', true, errors);
  assertBindingTier(root, debugConfig, 'Debug', false, errors);

  const schemes = parsed?.schemes;
  const archiveConfigs = [];
  if (schemes && typeof schemes === 'object') {
    for (const scheme of Object.values(schemes)) {
      const config = scheme?.archive?.config;
      if (typeof config === 'string') {
        archiveConfigs.push(config);
      }
    }
  }
  if (archiveConfigs.length === 0) {
    pushError(errors, 'project.yml declares no scheme archive configuration to verify');
  }
  // Exact match: a custom config like `Release-dev` must not be accepted as Release.
  for (const config of archiveConfigs) {
    if (config !== 'Release') {
      pushError(errors, `Every scheme must archive with the Release configuration, found archive config: ${config}`);
    }
  }
}

function assertBindingTier(root, relativePath, configurationName, expectProtected, errors) {
  if (!relativePath) {
    pushError(errors, `project.yml must bind the ${configurationName} configuration to an environment config file`);
    return;
  }
  let values;
  try {
    values = readXcconfigValues(join(root, relativePath));
  } catch {
    pushError(errors, `project.yml ${configurationName} binding points at an unreadable config: ${relativePath}`);
    return;
  }
  const isProtected = normalize(values.get('CATVOX_ENVIRONMENT_PROTECTED')) === 'true';
  if (isProtected !== expectProtected) {
    const tier = expectProtected ? 'protected' : 'mutable';
    pushError(
      errors,
      `project.yml binds the ${configurationName} configuration to ${relativePath}, which must be a ${tier} environment (CATVOX_ENVIRONMENT_PROTECTED=${expectProtected})`
    );
  }
}

function readFileOrNull(path) {
  if (!existsSync(path)) {
    return null;
  }
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
}

// Resolve which environment to validate. Explicit config/env wins; otherwise
// auto-discover the single protected environment under config/environments/.
function resolveTarget({ configArg, envArg, root }) {
  if (configArg) {
    return { configPath: resolve(repoRoot, configArg), environmentName: envArg };
  }
  if (process.env.CATVOX_ENV_CONFIG) {
    return { configPath: resolve(repoRoot, process.env.CATVOX_ENV_CONFIG), environmentName: envArg };
  }
  const environmentName = envArg || normalize(process.env.CATVOX_ENVIRONMENT);
  if (environmentName) {
    return {
      configPath: resolve(root, `config/environments/${environmentName}.xcconfig`),
      environmentName,
    };
  }
  return { configPath: discoverProtectedConfig(root), environmentName: undefined };
}

function discoverProtectedConfig(root) {
  const dir = join(root, 'config/environments');
  let entries = [];
  try {
    entries = readdirSync(dir).filter((name) => name.endsWith('.xcconfig'));
  } catch {
    throw new Error(`Cannot read environment configs under ${dir}`);
  }
  const found = [];
  for (const entry of entries) {
    try {
      const values = readXcconfigValues(join(dir, entry));
      if (normalize(values.get('CATVOX_ENVIRONMENT_PROTECTED')) === 'true') {
        found.push(join(dir, entry));
      }
    } catch {
      // Skip configs that fail to parse; the base validator covers them.
    }
  }
  if (found.length === 1) {
    return found[0];
  }
  if (found.length === 0) {
    throw new Error(
      'No protected environment config found (CATVOX_ENVIRONMENT_PROTECTED=true) under config/environments/'
    );
  }
  throw new Error(
    `Multiple protected environment configs found; specify one explicitly: ${found.join(', ')}`
  );
}

function main() {
  const args = process.argv.slice(2);
  const configArg = args.find((arg) => arg.startsWith('--config='))?.slice('--config='.length);
  const envArg = args.find((arg) => !arg.startsWith('--'));
  const { configPath, environmentName } = resolveTarget({ configArg, envArg, root: repoRoot });

  const result = validateReleaseSafety({ configPath, environmentName });
  console.log(`Release safety validated: ${result.configPath} (protected)`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}
