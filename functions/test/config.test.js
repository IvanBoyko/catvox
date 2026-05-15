const test = require('node:test');
const assert = require('node:assert/strict');

const {
  backendServiceAccount,
  backendServiceAccountOption,
  configuredProjectId,
  functionRegion,
  requiredProjectId,
  vertexLocation,
} = require('../lib/config.js');

test('configuredProjectId prefers CatVox-specific environment key', () => {
  assert.equal(
    configuredProjectId({
      CATVOX_PROJECT_ID: 'catvox-dev',
      GCP_PROJECT_ID: 'catvox-gcp',
      GCLOUD_PROJECT: 'catvox-cloud',
    }),
    'catvox-dev'
  );
});

test('requiredProjectId throws when no project is configured', () => {
  assert.throws(
    () => requiredProjectId({}),
    /Project ID is not configured/
  );
});

test('backendServiceAccount uses explicit override when present', () => {
  assert.equal(
    backendServiceAccount({
      CATVOX_BACKEND_SERVICE_ACCOUNT: 'custom@example.iam.gserviceaccount.com',
      CATVOX_PROJECT_ID: 'catvox-dev',
    }),
    'custom@example.iam.gserviceaccount.com'
  );
});

test('backendServiceAccount derives distinct account emails from each project', () => {
  assert.equal(
    backendServiceAccount({ CATVOX_PROJECT_ID: 'catvox-dev' }),
    'catvox-backend-sa@catvox-dev.iam.gserviceaccount.com'
  );
  assert.equal(
    backendServiceAccount({ CATVOX_PROJECT_ID: 'catvox-prod' }),
    'catvox-backend-sa@catvox-prod.iam.gserviceaccount.com'
  );
});

test('backendServiceAccountOption throws when service account cannot be derived', () => {
  assert.throws(
    () => backendServiceAccountOption({}),
    /Backend service account is not configured/
  );
});

test('backendServiceAccountOption allows default service account by explicit opt-in', () => {
  assert.deepEqual(
    backendServiceAccountOption({ CATVOX_ALLOW_DEFAULT_SERVICE_ACCOUNT: '1' }),
    {}
  );
});

test('functionRegion and vertexLocation use generic overrides with defaults', () => {
  assert.equal(functionRegion({}), 'us-central1');
  assert.equal(functionRegion({ CATVOX_FUNCTION_REGION: 'europe-west2' }), 'europe-west2');
  assert.equal(
    vertexLocation({
      CATVOX_FUNCTION_REGION: 'europe-west2',
      CATVOX_VERTEX_LOCATION: 'us-east1',
    }),
    'us-east1'
  );
});
