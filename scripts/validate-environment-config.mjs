#!/usr/bin/env node
// Environment-agnostic validator for config/environments/<env>.xcconfig.
//
// Validates ANY environment's committed config against environment-agnostic
// rules — it does not hard-code project IDs, bundle IDs, or per-environment
// "golden" values. Differences in behaviour come from the config itself
// (ADR-0017, ADR-0021, ADR-0026):
//   - required keys present and non-placeholder (deferred post-provisioning
//     keys may stay as placeholders until --require-live)
//   - internal consistency of identifiers derived from CATVOX_PROJECT_ID
//   - hostname-only / enum / boolean format
//   - no references to any OTHER committed environment
//   - protected environments (CATVOX_ENVIRONMENT_PROTECTED=true) must enforce
//     App Check, pin a WIF ref, use the ABANDON deletion policy, and stay out
//     of the integration-safe list (ADR-0024, ADR-0025)
//
// The only literals here are generic key names and enum values. Literal
// environment names ("dev"/"prod") belong in the CI/CD promotion pipeline, not
// in this validator.

import { existsSync, readdirSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import placeholderHelpers from './lib/config-placeholders.cjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { isPlaceholder } = placeholderHelpers;

// Keys every environment must declare with a real value, except those in
// deferredKeys (which may stay as placeholders until the environment is fully
// provisioned). This set is environment-agnostic — the same for any env.
export const requiredKeys = [
  'CATVOX_PROJECT_ID',
  'CATVOX_ENVIRONMENT',
  'CATVOX_ENVIRONMENT_PROTECTED',
  'CATVOX_FUNCTION_REGION',
  'CATVOX_FIRESTORE_LOCATION',
  'CATVOX_TF_STATE_BUCKET',
  'CATVOX_GCP_CI_SERVICE_ACCOUNT',
  'CATVOX_GCP_WIF_PROVIDER',
  'CATVOX_IOS_BUNDLE_ID',
  'CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME',
  'CATVOX_FIREBASE_IOS_APP_DELETION_POLICY',
  'CATVOX_FIREBASE_APPLE_TEAM_ID',
  'CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT',
  'CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM',
  'CATVOX_SIGNED_UPLOAD_URL_HOST',
  'CATVOX_ANALYSE_VIDEO_HOST',
  'CATVOX_FIREBASE_APP_ID',
  'CATVOX_FIREBASE_API_KEY',
  'CATVOX_POSTHOG_PROJECT_TOKEN',
  'CATVOX_POSTHOG_HOST_NAME',
  'CATVOX_POSTHOG_API_HOST_NAME',
  'CATVOX_POSTHOG_PROJECT_ID',
  'CATVOX_POSTHOG_ORGANIZATION_ID',
];

// Values populated only after the environment's first Terraform apply, Functions
// deploy, or PostHog project creation. They may remain `replace-with-*`
// placeholders until then so a Release build fails loudly rather than shipping
// wrong values. Environment-agnostic: the same keys are deferred for any env.
export const deferredKeys = new Set([
  'CATVOX_FIREBASE_APP_ID',
  'CATVOX_FIREBASE_API_KEY',
  'CATVOX_SIGNED_UPLOAD_URL_HOST',
  'CATVOX_ANALYSE_VIDEO_HOST',
  'CATVOX_POSTHOG_PROJECT_TOKEN',
  'CATVOX_POSTHOG_PROJECT_ID',
]);

const enforcementModes = ['OFF', 'UNENFORCED', 'ENFORCED'];
const deletionPolicies = ['ABANDON', 'DELETE'];

export function validateEnvironmentConfig({
  configPath,
  environmentName,
  requireLive = false,
} = {}) {
  const values = readXcconfigValues(configPath);
  const errors = [];
  const deferredPlaceholders = [];

  const declaredEnv = normalize(values.get('CATVOX_ENVIRONMENT'));
  const projectId = normalize(values.get('CATVOX_PROJECT_ID'));
  const env = environmentName || declaredEnv;

  // The config must self-identify as the environment it is validated as.
  if (environmentName && declaredEnv && declaredEnv !== environmentName) {
    errors.push(
      `CATVOX_ENVIRONMENT is ${declaredEnv} but the config is being validated as ${environmentName} (${configPath})`
    );
  }

  // Required keys present and not placeholders (deferred allowed unless requireLive).
  for (const key of requiredKeys) {
    const value = normalize(values.get(key));
    if (!value) {
      errors.push(`${key} is required in ${configPath}`);
      continue;
    }
    if (isPlaceholder(value)) {
      if (deferredKeys.has(key) && !requireLive) {
        deferredPlaceholders.push(key);
      } else {
        errors.push(`${key} must not be a placeholder in ${configPath}`);
      }
    }
  }

  // Internal consistency: identifiers derived from the project ID must match.
  if (projectId) {
    assertEquals(errors, values, 'CATVOX_TF_STATE_BUCKET', `catvox-tf-state-${projectId}`);
    assertEquals(
      errors,
      values,
      'CATVOX_GCP_CI_SERVICE_ACCOUNT',
      `catvox-ci-sa@${projectId}.iam.gserviceaccount.com`
    );
  }

  const wifProvider = normalize(values.get('CATVOX_GCP_WIF_PROVIDER'));
  if (
    wifProvider &&
    !/^projects\/\d+\/locations\/global\/workloadIdentityPools\/[^/]+\/providers\/[^/]+$/.test(
      wifProvider
    )
  ) {
    errors.push(`CATVOX_GCP_WIF_PROVIDER is not a valid WIF provider resource name: ${wifProvider}`);
  }

  // Hostname-only fields.
  for (const [key, value] of values) {
    if ((key.endsWith('_HOST') || key.endsWith('_HOST_NAME')) && value.includes('/')) {
      errors.push(`${key} must be a hostname only, got ${value}`);
    }
  }

  // No references to any OTHER committed environment's project or bundle id.
  // Project IDs are matched as substrings (they appear inside derived bucket /
  // service-account names); bundle IDs are matched exactly to avoid flagging a
  // longer bundle that merely shares a prefix (e.g. com.kathelix.catvox.dev
  // contains com.kathelix.catvox).
  const foreign = collectForeignIdentifiers(configPath);
  for (const [key, value] of values) {
    for (const projectRef of foreign.projectIds) {
      if (value.includes(projectRef)) {
        errors.push(`${key} must not reference another environment's project (${projectRef})`);
      }
    }
    if (foreign.bundleIds.has(value)) {
      errors.push(`${key} must not reference another environment's bundle id (${value})`);
    }
  }

  // Enum / boolean validity.
  const enforcement = normalize(values.get('CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT'));
  if (enforcement && !enforcementModes.includes(enforcement)) {
    errors.push(
      `CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT must be one of ${enforcementModes.join(', ')}, got ${enforcement}`
    );
  }
  const deletion = normalize(values.get('CATVOX_FIREBASE_IOS_APP_DELETION_POLICY'));
  if (deletion && !deletionPolicies.includes(deletion)) {
    errors.push(
      `CATVOX_FIREBASE_IOS_APP_DELETION_POLICY must be one of ${deletionPolicies.join(', ')}, got ${deletion}`
    );
  }
  const protectedRaw = normalize(values.get('CATVOX_ENVIRONMENT_PROTECTED'));
  if (protectedRaw && protectedRaw !== 'true' && protectedRaw !== 'false') {
    errors.push(`CATVOX_ENVIRONMENT_PROTECTED must be true or false, got ${protectedRaw}`);
  }

  // Protected-tier security invariants (ADR-0024, ADR-0025, ADR-0026).
  const isProtected = protectedRaw === 'true';
  if (isProtected) {
    if (enforcement && enforcement !== 'ENFORCED') {
      errors.push(
        `Protected environment requires CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT=ENFORCED, got ${enforcement}`
      );
    }
    if (!normalize(values.get('CATVOX_GCP_WIF_GITHUB_REF'))) {
      errors.push(
        'Protected environment requires CATVOX_GCP_WIF_GITHUB_REF to pin a ref (for example refs/heads/main)'
      );
    }
    if (deletion && deletion !== 'ABANDON') {
      errors.push(
        `Protected environment requires CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=ABANDON, got ${deletion}`
      );
    }
    if (env && parseList(values.get('CATVOX_INTEGRATION_SAFE_ENVIRONMENTS')).has(env)) {
      errors.push(
        `Protected environment ${env} must not be listed in CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`
      );
    }
  }

  if (errors.length > 0) {
    throw new Error(errors.join('\n'));
  }

  return { configPath, environmentName: env, isProtected, values, deferredPlaceholders };
}

function assertEquals(errors, values, key, expected) {
  const actual = normalize(values.get(key));
  if (actual && actual !== expected) {
    errors.push(`${key} must be ${expected}, got ${actual}`);
  }
}

// Collect project IDs and bundle IDs declared by every OTHER committed
// environment config, so cross-environment references can be flagged. Sibling
// configs that fail to parse are skipped rather than failing this validation.
export function collectForeignIdentifiers(configPath) {
  const absolute = resolve(repoRoot, configPath);
  const dir = dirname(absolute);
  const self = basename(absolute);
  const projectIds = new Set();
  const bundleIds = new Set();

  let entries = [];
  try {
    entries = readdirSync(dir).filter((name) => name.endsWith('.xcconfig') && name !== self);
  } catch {
    return { projectIds, bundleIds };
  }

  for (const entry of entries) {
    let siblingValues;
    try {
      siblingValues = readXcconfigValues(join(dir, entry));
    } catch {
      continue;
    }
    const projectId = normalize(siblingValues.get('CATVOX_PROJECT_ID'));
    const bundleId = normalize(siblingValues.get('CATVOX_IOS_BUNDLE_ID'));
    if (projectId && !isPlaceholder(projectId)) {
      projectIds.add(projectId);
    }
    if (bundleId && !isPlaceholder(bundleId)) {
      bundleIds.add(bundleId);
    }
  }
  return { projectIds, bundleIds };
}

export function readXcconfigValues(configPath) {
  if (!existsSync(configPath)) {
    throw new Error(`Missing xcconfig file: ${configPath}`);
  }

  const emit = spawnSync(
    'bash',
    [resolve(repoRoot, 'scripts/lib/emit-xcconfig-env.sh'), '--format=sh', configPath],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  if (emit.status !== 0) {
    throw new Error((emit.stderr || emit.stdout || 'xcconfig validation failed').trim());
  }

  const parsed = spawnSync(
    'awk',
    ['-f', resolve(repoRoot, 'scripts/lib/xcconfig-parse.awk'), '-v', 'mode=all', configPath],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  if (parsed.status !== 0) {
    throw new Error((parsed.stderr || 'xcconfig parsing failed').trim());
  }

  const values = new Map();
  for (const line of parsed.stdout.split(/\r?\n/)) {
    if (!line) {
      continue;
    }
    const separator = line.indexOf('\t');
    if (separator === -1) {
      continue;
    }
    values.set(line.slice(0, separator), line.slice(separator + 1));
  }
  return values;
}

export function normalize(value) {
  if (value === undefined || value === null) {
    return undefined;
  }
  const trimmed = String(value).trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export function parseList(value) {
  return new Set(
    (value || '')
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item.length > 0)
  );
}

function main() {
  const args = process.argv.slice(2);
  const requireLive =
    args.includes('--require-live') || process.env.CATVOX_REQUIRE_LIVE_CONFIG === '1';
  const configArg = args.find((arg) => arg.startsWith('--config='));
  const envArg = args.find((arg) => !arg.startsWith('--'));
  const environmentName = envArg || normalize(process.env.CATVOX_ENVIRONMENT);

  let configPath;
  if (configArg) {
    configPath = resolve(repoRoot, configArg.slice('--config='.length));
  } else if (process.env.CATVOX_ENV_CONFIG) {
    configPath = resolve(repoRoot, process.env.CATVOX_ENV_CONFIG);
  } else if (environmentName) {
    configPath = resolve(repoRoot, `config/environments/${environmentName}.xcconfig`);
  } else {
    throw new Error(
      'Specify an environment: validate-environment-config.mjs <env> (or --config=<path>, or CATVOX_ENVIRONMENT)'
    );
  }

  const result = validateEnvironmentConfig({ configPath, environmentName, requireLive });
  console.log(
    `Environment config validated: ${result.configPath}${result.isProtected ? ' (protected)' : ''}`
  );
  if (result.deferredPlaceholders.length > 0) {
    console.log(
      `Deferred placeholders allowed (provisioned after apply): ${result.deferredPlaceholders.join(', ')}`
    );
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}
