// Focused coverage for scripts/validate-environment-config.mjs — the
// environment-agnostic config validator (ADR-0024/0025/0026). Run with
// `make scripts-test` or `node --test scripts/test/validate-environment-config.test.mjs`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateEnvironmentConfig } from '../validate-environment-config.mjs';

// A complete, internally-consistent, non-placeholder config for a fictional
// environment. Overrides let each test perturb exactly one property.
function baseConfig(overrides = {}) {
  const values = {
    CATVOX_PROJECT_ID: 'kathelix-catvox-sample',
    CATVOX_ENVIRONMENT: 'sample',
    CATVOX_ENVIRONMENT_PROTECTED: 'false',
    CATVOX_FUNCTION_REGION: 'us-central1',
    CATVOX_FIRESTORE_LOCATION: 'nam5',
    CATVOX_TF_STATE_BUCKET: 'catvox-tf-state-kathelix-catvox-sample',
    CATVOX_GCP_CI_SERVICE_ACCOUNT: 'catvox-ci-sa@kathelix-catvox-sample.iam.gserviceaccount.com',
    CATVOX_GCP_WIF_PROVIDER:
      'projects/123456789/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider',
    CATVOX_GCP_WIF_GITHUB_REF: '',
    CATVOX_IOS_BUNDLE_ID: 'com.kathelix.catvox.sample',
    CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'CatVox Sample iOS',
    CATVOX_FIREBASE_IOS_APP_DELETION_POLICY: 'DELETE',
    CATVOX_FIREBASE_APPLE_TEAM_ID: 'QYT76L5836',
    CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT: 'UNENFORCED',
    CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM: 'true',
    CATVOX_SIGNED_UPLOAD_URL_HOST: 'signed.sample.run.app',
    CATVOX_ANALYSE_VIDEO_HOST: 'analyse.sample.run.app',
    CATVOX_FIREBASE_APP_ID: '1:123:ios:sample',
    CATVOX_FIREBASE_API_KEY: 'AIzaSAMPLEKEY',
    CATVOX_POSTHOG_PROJECT_TOKEN: 'phc_sample',
    CATVOX_POSTHOG_HOST_NAME: 'us.i.posthog.com',
    CATVOX_POSTHOG_API_HOST_NAME: 'us.posthog.com',
    CATVOX_POSTHOG_PROJECT_ID: '11111',
    CATVOX_POSTHOG_ORGANIZATION_ID: 'org-sample',
    CATVOX_INTEGRATION_SAFE_ENVIRONMENTS: 'sample',
    ...overrides,
  };
  return (
    Object.entries(values)
      .map(([key, value]) => `${key} = ${value}`)
      .join('\n') + '\n'
  );
}

function writeConfig(name, overrides = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-env-validate-'));
  const configPath = join(dir, `${name}.xcconfig`);
  writeFileSync(configPath, baseConfig({ CATVOX_ENVIRONMENT: name, ...overrides }));
  return { dir, configPath };
}

const PROTECTED = {
  CATVOX_ENVIRONMENT_PROTECTED: 'true',
  CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT: 'ENFORCED',
  CATVOX_GCP_WIF_GITHUB_REF: 'refs/heads/main',
  CATVOX_FIREBASE_IOS_APP_DELETION_POLICY: 'ABANDON',
  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS: '',
};

test('a non-protected config validates', () => {
  const { configPath } = writeConfig('sample');
  const result = validateEnvironmentConfig({ configPath, environmentName: 'sample' });
  assert.equal(result.isProtected, false);
});

test('a fully-postured protected config validates', () => {
  const { configPath } = writeConfig('shielded', PROTECTED);
  const result = validateEnvironmentConfig({ configPath, environmentName: 'shielded' });
  assert.equal(result.isProtected, true);
});

test('protected environment must enforce App Check on Firestore', () => {
  const { configPath } = writeConfig('shielded', {
    ...PROTECTED,
    CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT: 'UNENFORCED',
  });
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'shielded' }),
    /ENFORCED/
  );
});

test('protected environment must pin a WIF ref', () => {
  const { configPath } = writeConfig('shielded', { ...PROTECTED, CATVOX_GCP_WIF_GITHUB_REF: '' });
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'shielded' }),
    /CATVOX_GCP_WIF_GITHUB_REF/
  );
});

test('protected environment must use ABANDON deletion policy', () => {
  const { configPath } = writeConfig('shielded', {
    ...PROTECTED,
    CATVOX_FIREBASE_IOS_APP_DELETION_POLICY: 'DELETE',
  });
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'shielded' }),
    /ABANDON/
  );
});

test('protected environment must not be integration-safe', () => {
  const { configPath } = writeConfig('shielded', {
    ...PROTECTED,
    CATVOX_INTEGRATION_SAFE_ENVIRONMENTS: 'shielded',
  });
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'shielded' }),
    /INTEGRATION_SAFE_ENVIRONMENTS/
  );
});

test('state bucket must be derived from the project id', () => {
  const { configPath } = writeConfig('sample', {
    CATVOX_TF_STATE_BUCKET: 'catvox-tf-state-someone-else',
  });
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'sample' }),
    /CATVOX_TF_STATE_BUCKET must be/
  );
});

test('a reference to another environment is rejected', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-env-validate-'));
  // Sibling environment in the same directory whose identifiers must not leak.
  writeFileSync(
    join(dir, 'other.xcconfig'),
    baseConfig({
      CATVOX_ENVIRONMENT: 'other',
      CATVOX_PROJECT_ID: 'kathelix-catvox-other',
      CATVOX_TF_STATE_BUCKET: 'catvox-tf-state-kathelix-catvox-other',
      CATVOX_GCP_CI_SERVICE_ACCOUNT: 'catvox-ci-sa@kathelix-catvox-other.iam.gserviceaccount.com',
      CATVOX_IOS_BUNDLE_ID: 'com.kathelix.catvox.other',
    })
  );
  const configPath = join(dir, 'sample.xcconfig');
  writeFileSync(
    configPath,
    baseConfig({
      CATVOX_ENVIRONMENT: 'sample',
      CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'CatVox kathelix-catvox-other iOS',
    })
  );
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'sample' }),
    /another environment's project/
  );
});

test('a non-deferred placeholder is rejected', () => {
  const { configPath } = writeConfig('sample', { CATVOX_FIREBASE_APPLE_TEAM_ID: '<replace-me>' });
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'sample' }),
    /must not be a placeholder/
  );
});

test('deferred placeholders are allowed by default but forbidden with requireLive', () => {
  const overrides = {
    CATVOX_FIREBASE_APP_ID: 'replace-with-app-id',
    CATVOX_SIGNED_UPLOAD_URL_HOST: 'replace-with-host',
  };
  const allowed = writeConfig('sample', overrides);
  const result = validateEnvironmentConfig({
    configPath: allowed.configPath,
    environmentName: 'sample',
  });
  assert.ok(result.deferredPlaceholders.includes('CATVOX_FIREBASE_APP_ID'));

  const strict = writeConfig('sample', overrides);
  assert.throws(
    () =>
      validateEnvironmentConfig({
        configPath: strict.configPath,
        environmentName: 'sample',
        requireLive: true,
      }),
    /must not be a placeholder/
  );
});

test('the declared environment must match the validated name', () => {
  const { configPath } = writeConfig('sample');
  assert.throws(
    () => validateEnvironmentConfig({ configPath, environmentName: 'mismatch' }),
    /being validated as/
  );
});
