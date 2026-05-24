#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { request } from 'node:https';
import { fileURLToPath } from 'node:url';
import {
  deferredProdKeys,
  normalize,
  validateProdEnvironmentConfig,
} from './validate-prod-environment-config.mjs';
import placeholderHelpers from './lib/config-placeholders.cjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { isPlaceholder } = placeholderHelpers;
const requireLive = process.env.CATVOX_PROD_SMOKE_REQUIRE_LIVE === '1';
const skipped = [];
let values;
let deferred;

try {
  await main();
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
}

async function main() {
  const result = validateProdEnvironmentConfig({
    configPath: resolve(repoRoot, 'config/environments/prod.xcconfig'),
    requireLiveValues: requireLive,
  });

  values = result.values;
  deferred = new Set(result.deferredPlaceholders);

  console.log('ok: prod xcconfig structural checks passed');

  await runFirebasePlistCheck();
  await runTerraformRefreshOnlyPlan();
  await runFirestoreDescribe();
  await runEndpointAppCheckProbe('getSignedUploadURL', values.get('CATVOX_SIGNED_UPLOAD_URL_HOST'));
  await runEndpointAppCheckProbe('analyseVideo', values.get('CATVOX_ANALYSE_VIDEO_HOST'));

  if (requireLive && skipped.length > 0) {
    throw new Error(`Prod smoke required live checks, but skipped: ${skipped.join('; ')}`);
  }

  if (skipped.length > 0) {
    console.log(`skipped: ${skipped.join('; ')}`);
  }
  console.log('Prod smoke completed without mutations.');
}

async function runFirebasePlistCheck() {
  const plistPath = resolve(repoRoot, 'CatVox/Resources/Firebase/GoogleService-Info-prod.plist');
  if (!existsSync(plistPath)) {
    skip('Firebase plist validation', 'GoogleService-Info-prod.plist is deferred to Step 3');
    return;
  }

  if (hasDeferredFirebasePlaceholder()) {
    skip('Firebase plist validation', 'Firebase app ID/API key are still Step 3 placeholders');
    return;
  }

  runChecked('node', ['scripts/validate-firebase-ios-config.mjs'], {
    ...process.env,
    CATVOX_ENVIRONMENT: 'prod',
    CATVOX_ENV_CONFIG: 'config/environments/prod.xcconfig',
    CATVOX_PROJECT_ID: requiredValue('CATVOX_PROJECT_ID'),
    CATVOX_FIREBASE_APP_ID: requiredValue('CATVOX_FIREBASE_APP_ID'),
    CATVOX_FIREBASE_API_KEY: requiredValue('CATVOX_FIREBASE_API_KEY'),
    CATVOX_IOS_BUNDLE_ID: requiredValue('CATVOX_IOS_BUNDLE_ID'),
  });
  console.log('ok: prod Firebase plist matches prod xcconfig');
}

async function runTerraformRefreshOnlyPlan() {
  if (!liveConfigReady()) {
    skip('Terraform refresh-only plan', 'live Prod config is deferred to Step 3');
    return;
  }

  if (!commandExists('terraform')) {
    skip('Terraform refresh-only plan', 'terraform CLI is not installed');
    return;
  }

  const tfvarsPath = resolve(repoRoot, 'terraform/env/prod.tfvars');
  if (!process.env.TF_VAR_alert_email && !existsSync(tfvarsPath)) {
    skip('Terraform refresh-only plan', 'TF_VAR_alert_email or terraform/env/prod.tfvars is required');
    return;
  }

  const terraformEnv = terraformEnvironment();
  runChecked('terraform', [
    '-chdir=terraform',
    'init',
    '-reconfigure',
    `-backend-config=bucket=${requiredValue('CATVOX_TF_STATE_BUCKET')}`,
    '-backend-config=prefix=catvox/state',
  ], terraformEnv);
  runChecked('terraform', [
    '-chdir=terraform',
    'plan',
    '-refresh-only',
    '-no-color',
    ...(existsSync(tfvarsPath) ? ['-var-file=env/prod.tfvars'] : []),
  ], terraformEnv);
  console.log('ok: terraform refresh-only plan completed');
}

async function runFirestoreDescribe() {
  if (!liveConfigReady()) {
    skip('Firestore database describe', 'live Prod config is deferred to Step 3');
    return;
  }

  if (!commandExists('gcloud')) {
    skip('Firestore database describe', 'gcloud CLI is not installed');
    return;
  }

  runChecked('gcloud', [
    'firestore',
    'databases',
    'describe',
    '--database=(default)',
    `--project=${requiredValue('CATVOX_PROJECT_ID')}`,
    '--format=value(name)',
  ]);
  console.log('ok: Firestore default database is readable');
}

async function runEndpointAppCheckProbe(name, host) {
  const normalizedHost = normalize(host);
  if (!normalizedHost || isPlaceholder(normalizedHost)) {
    skip(`${name} endpoint liveness`, 'backend endpoint host is deferred to Step 3');
    return;
  }

  const response = await getJson(`https://${normalizedHost}`);
  if (response.statusCode !== 401 || response.body.code !== 'app_check_unauthorized') {
    throw new Error(
      `${name} expected 401 app_check_unauthorized, got ${response.statusCode}: ` +
      JSON.stringify(response.body)
    );
  }
  console.log(`ok: ${name} is reachable and rejects missing App Check before mutation`);
}

function liveConfigReady() {
  for (const key of deferredProdKeys) {
    const value = normalize(values.get(key));
    if (!value || isPlaceholder(value)) {
      return false;
    }
  }
  return true;
}

function hasDeferredFirebasePlaceholder() {
  return ['CATVOX_FIREBASE_APP_ID', 'CATVOX_FIREBASE_API_KEY'].some((key) => deferred.has(key));
}

function requiredValue(key) {
  const value = normalize(values.get(key));
  if (!value) {
    throw new Error(`${key} is required`);
  }
  return value;
}

function terraformEnvironment() {
  return {
    ...process.env,
    GOOGLE_CLOUD_QUOTA_PROJECT: requiredValue('CATVOX_PROJECT_ID'),
    TF_VAR_environment_name: 'prod',
    TF_VAR_project_id: requiredValue('CATVOX_PROJECT_ID'),
    TF_VAR_region: requiredValue('CATVOX_FUNCTION_REGION'),
    TF_VAR_firestore_location: requiredValue('CATVOX_FIRESTORE_LOCATION'),
    TF_VAR_tf_state_bucket: requiredValue('CATVOX_TF_STATE_BUCKET'),
    TF_VAR_firebase_ios_bundle_id: requiredValue('CATVOX_IOS_BUNDLE_ID'),
    TF_VAR_firebase_ios_app_display_name: requiredValue('CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME'),
    TF_VAR_firebase_ios_app_deletion_policy: requiredValue('CATVOX_FIREBASE_IOS_APP_DELETION_POLICY'),
    TF_VAR_firebase_apple_team_id: requiredValue('CATVOX_FIREBASE_APPLE_TEAM_ID'),
    TF_VAR_manage_gcf_sources_bucket_iam: requiredValue('CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM'),
  };
}

function runChecked(command, args, env = process.env) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env,
    encoding: 'utf8',
    stdio: 'inherit',
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed`);
  }
}

function commandExists(command) {
  const result = spawnSync('sh', ['-c', 'command -v "$1" >/dev/null 2>&1', 'sh', command], {
    encoding: 'utf8',
  });
  return result.status === 0;
}

function skip(name, reason) {
  skipped.push(`${name} (${reason})`);
}

function getJson(url) {
  return new Promise((resolveRequest, reject) => {
    const req = request(url, { method: 'GET', timeout: 15000 }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        raw += chunk;
      });
      res.on('end', () => {
        let body = {};
        try {
          body = raw ? JSON.parse(raw) : {};
        } catch {
          body = { raw };
        }
        resolveRequest({ statusCode: res.statusCode, body });
      });
    });
    req.on('timeout', () => {
      req.destroy(new Error(`Timed out requesting ${url}`));
    });
    req.on('error', reject);
    req.end();
  });
}
