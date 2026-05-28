#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import placeholderHelpers from './lib/config-placeholders.cjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..');
const { isPlaceholder } = placeholderHelpers;

export const deferredProdKeys = new Set([
  'CATVOX_FIREBASE_APP_ID',
  'CATVOX_FIREBASE_API_KEY',
  'CATVOX_SIGNED_UPLOAD_URL_HOST',
  'CATVOX_ANALYSE_VIDEO_HOST',
  // Populated after the first terraform apply for the Prod PostHog project
  // creates the project ID and emits its ingestion token. Until then they
  // stay as `replace-with-prod-*` placeholders so the iOS Release build
  // would noisily fail rather than silently send events to the wrong target.
  'CATVOX_POSTHOG_PROJECT_TOKEN',
  'CATVOX_POSTHOG_PROJECT_ID',
]);

const requiredProdKeys = [
  'CATVOX_PROJECT_ID',
  'CATVOX_ENVIRONMENT',
  'CATVOX_FUNCTION_REGION',
  'CATVOX_FIRESTORE_LOCATION',
  'CATVOX_TF_STATE_BUCKET',
  'CATVOX_GCP_CI_SERVICE_ACCOUNT',
  'CATVOX_GCP_WIF_PROVIDER',
  'CATVOX_IOS_BUNDLE_ID',
  'CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME',
  'CATVOX_FIREBASE_IOS_APP_DELETION_POLICY',
  'CATVOX_FIREBASE_APPLE_TEAM_ID',
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

const exactProdValues = new Map([
  ['CATVOX_PROJECT_ID', 'kathelix-catvox-prod'],
  ['CATVOX_ENVIRONMENT', 'prod'],
  ['CATVOX_FUNCTION_REGION', 'us-central1'],
  ['CATVOX_FIRESTORE_LOCATION', 'nam5'],
  ['CATVOX_TF_STATE_BUCKET', 'catvox-tf-state-kathelix-catvox-prod'],
  ['CATVOX_GCP_CI_SERVICE_ACCOUNT', 'catvox-ci-sa@kathelix-catvox-prod.iam.gserviceaccount.com'],
  [
    'CATVOX_GCP_WIF_PROVIDER',
    'projects/953500951129/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider',
  ],
  ['CATVOX_IOS_BUNDLE_ID', 'com.kathelix.catvox'],
  ['CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME', 'CatVox Prod iOS'],
  ['CATVOX_FIREBASE_IOS_APP_DELETION_POLICY', 'ABANDON'],
  ['CATVOX_FIREBASE_APPLE_TEAM_ID', 'QYT76L5836'],
  ['CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM', 'true'],
]);

export function validateProdEnvironmentConfig({
  configPath = resolve(repoRoot, 'config/environments/prod.xcconfig'),
  requireLiveValues = false,
} = {}) {
  const values = readXcconfigValues(configPath);
  const errors = [];
  const deferredPlaceholders = [];

  for (const key of requiredProdKeys) {
    const value = normalize(values.get(key));
    if (!value) {
      errors.push(`${key} is required in ${configPath}`);
      continue;
    }

    if (isPlaceholder(value)) {
      if (deferredProdKeys.has(key) && !requireLiveValues) {
        deferredPlaceholders.push(key);
      } else {
        errors.push(`${key} must not be a placeholder in ${configPath}`);
      }
    }
  }

  for (const [key, expected] of exactProdValues) {
    const actual = normalize(values.get(key));
    if (actual && actual !== expected) {
      errors.push(`${key} must be ${expected}, got ${actual}`);
    }
  }

  for (const [key, value] of values) {
    if (key.endsWith('_HOST') || key.endsWith('_HOST_NAME')) {
      if (value.includes('/')) {
        errors.push(`${key} must be a hostname only, got ${value}`);
      }
    }

    if (value.includes('kathelix-catvox-dev') || value.includes('com.kathelix.catvox.dev')) {
      errors.push(`${key} must not reference Dev from Prod config`);
    }
  }

  const safeEnvironments = parseList(values.get('CATVOX_INTEGRATION_SAFE_ENVIRONMENTS'));
  if (safeEnvironments.has('prod')) {
    errors.push('CATVOX_INTEGRATION_SAFE_ENVIRONMENTS must not include prod');
  }

  if (errors.length > 0) {
    throw new Error(errors.join('\n'));
  }

  return {
    configPath,
    values,
    deferredPlaceholders,
  };
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
  const requireLiveValues =
    process.argv.includes('--require-live') ||
    process.env.CATVOX_REQUIRE_PROD_LIVE_CONFIG === '1';
  const configArg = process.argv.find((arg) => arg.startsWith('--config='));
  const configPath = configArg
    ? resolve(repoRoot, configArg.slice('--config='.length))
    : resolve(repoRoot, process.env.CATVOX_ENV_CONFIG || 'config/environments/prod.xcconfig');

  const result = validateProdEnvironmentConfig({ configPath, requireLiveValues });
  console.log(`Prod environment config structure validated: ${result.configPath}`);
  if (result.deferredPlaceholders.length > 0) {
    console.log(
      `Deferred Step 3 placeholders allowed for now: ${result.deferredPlaceholders.join(', ')}`
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
