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

  assertProtectedPosture(values, env, errors);
  assertNoDebugTokenKeys(values, errors);
  assertAppAttestEntitlement(
    resolveEntitlementsPath({ explicit: entitlementsPath, projectSpec, root, errors }),
    errors
  );
  assertNoForeignIdentifiers(values, absConfig, errors);
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
function assertNoDebugTokenKeys(values, errors) {
  for (const key of debugTokenKeys) {
    if (normalize(values.get(key))) {
      pushError(
        errors,
        `${key} must not be set in a protected Release config (App Check debug tokens are mutable-tier only)`
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
  const match = projectSpec.match(/CODE_SIGN_ENTITLEMENTS:\s*(\S+)/);
  if (!match) {
    pushError(
      errors,
      'project.yml must set CODE_SIGN_ENTITLEMENTS for the app target so the Release build signs with the committed entitlements'
    );
    return null;
  }
  return join(root, match[1]);
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

// (c) The heart of the leak check: no value the Release build embeds may
// reference another committed environment. Project ids match as substrings
// (they appear inside derived bucket / service-account / app-id strings);
// bundle ids match exactly (so a longer bundle that merely shares a prefix is
// not flagged); Firebase app ids and endpoint hosts match as substrings. The
// scan surface includes the composed https:// endpoints exactly as project.yml
// writes them into Info.plist, not just the bare hostname fields.
function assertNoForeignIdentifiers(values, configPath, errors) {
  const foreign = collectForeignReleaseIdentifiers(configPath);

  const scan = [...values.entries()];
  const signedHost = normalize(values.get('CATVOX_SIGNED_UPLOAD_URL_HOST'));
  const analyseHost = normalize(values.get('CATVOX_ANALYSE_VIDEO_HOST'));
  const postHogHost = normalize(values.get('CATVOX_POSTHOG_HOST_NAME'));
  if (signedHost) scan.push(['CatVoxSignedUploadURLEndpoint', `https://${signedHost}`]);
  if (analyseHost) scan.push(['CatVoxAnalyseVideoEndpoint', `https://${analyseHost}`]);
  if (postHogHost) scan.push(['CatVoxPostHogHost', `https://${postHogHost}`]);

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

// Gather the identifiers of every OTHER committed environment in the same
// directory. Extends the project/bundle pair scanned by the base validator with
// Firebase app ids and backend endpoint hosts. Placeholders and unparseable
// siblings are skipped.
export function collectForeignReleaseIdentifiers(configPath) {
  const absolute = resolve(configPath);
  const dir = dirname(absolute);
  const self = basename(absolute);
  const projectIds = new Set();
  const bundleIds = new Set();
  const firebaseAppIds = new Set();
  const endpointHosts = new Set();
  const posthogTokens = new Set();
  const posthogProjectIds = new Set();

  let entries = [];
  try {
    entries = readdirSync(dir).filter((name) => name.endsWith('.xcconfig') && name !== self);
  } catch {
    return { projectIds, bundleIds, firebaseAppIds, endpointHosts, posthogTokens, posthogProjectIds };
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
    addIfReal(endpointHosts, values.get('CATVOX_SIGNED_UPLOAD_URL_HOST'));
    addIfReal(endpointHosts, values.get('CATVOX_ANALYSE_VIDEO_HOST'));
    // PostHog: only the per-project token and id are environment-unique and ship
    // in the app (project.yml embeds the token as CatVoxPostHogProjectToken). The
    // PostHog host and organization id are deliberately shared across
    // environments, so they are not treated as foreign (ADR-0019, ADR-0020).
    addIfReal(posthogTokens, values.get('CATVOX_POSTHOG_PROJECT_TOKEN'));
    addIfReal(posthogProjectIds, values.get('CATVOX_POSTHOG_PROJECT_ID'));
  }
  return { projectIds, bundleIds, firebaseAppIds, endpointHosts, posthogTokens, posthogProjectIds };
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

// (g) project.yml must bind the Release configuration to the protected tier and
// the Debug configuration to a mutable tier, and every scheme must archive with
// Release. Resolved through the configs themselves, so no environment is named.
export function assertArchiveBinding(spec, root, errors) {
  if (spec == null) {
    return; // project.yml read error already reported
  }

  const bindings = new Map();
  const bindingRe = /^\s*(Debug|Release):\s*(config\/environments\/\S+\.xcconfig)\s*$/gm;
  let match;
  while ((match = bindingRe.exec(spec)) !== null) {
    bindings.set(match[1], match[2]);
  }

  assertBindingTier(root, bindings.get('Release'), 'Release', true, errors);
  assertBindingTier(root, bindings.get('Debug'), 'Debug', false, errors);

  const archiveConfigs = [...spec.matchAll(/archive:\s*\n\s*config:\s*(\w+)/g)].map((m) => m[1]);
  if (archiveConfigs.length === 0) {
    pushError(errors, 'project.yml declares no scheme archive configuration to verify');
  }
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
