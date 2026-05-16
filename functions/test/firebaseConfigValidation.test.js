const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');

const script = join(__dirname, '..', '..', 'scripts', 'validate-firebase-ios-config.mjs');

function runValidator(plistPath, overrides = {}) {
  return execFileSync('node', [script], {
    encoding: 'utf8',
    env: {
      ...process.env,
      CATVOX_ENVIRONMENT: 'dev',
      CATVOX_PROJECT_ID: 'catvox-dev',
      CATVOX_FIREBASE_APP_ID: '1:123:ios:abc',
      CATVOX_FIREBASE_API_KEY: 'api-key',
      CATVOX_IOS_BUNDLE_ID: 'com.kathelix.catvox.dev',
      CATVOX_FIREBASE_PLIST_PATH: plistPath,
      ...overrides,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function plist(values) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>API_KEY</key>
  <string>${values.apiKey}</string>
  <key>BUNDLE_ID</key>
  <string>${values.bundleId}</string>
  <key>GOOGLE_APP_ID</key>
  <string>${values.appId}</string>
  <key>PROJECT_ID</key>
  <string>${values.projectId}</string>
</dict>
</plist>
`;
}

test('Firebase iOS config validator accepts matching plist values', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-firebase-'));
  const file = join(dir, 'GoogleService-Info-dev.plist');

  try {
    writeFileSync(
      file,
      plist({
        apiKey: 'api-key',
        bundleId: 'com.kathelix.catvox.dev',
        appId: '1:123:ios:abc',
        projectId: 'catvox-dev',
      })
    );

    assert.match(runValidator(file), /Firebase iOS config validated/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('Firebase iOS config validator rejects project mismatches', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-firebase-'));
  const file = join(dir, 'GoogleService-Info-dev.plist');

  try {
    writeFileSync(
      file,
      plist({
        apiKey: 'api-key',
        bundleId: 'com.kathelix.catvox.dev',
        appId: '1:123:ios:abc',
        projectId: 'wrong-project',
      })
    );

    assert.throws(
      () => runValidator(file),
      (error) => {
        assert.match(error.stderr.toString(), /PROJECT_ID/);
        return true;
      }
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('Firebase iOS config validator rejects placeholder environment values', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-firebase-'));
  const file = join(dir, 'GoogleService-Info-dev.plist');

  try {
    writeFileSync(
      file,
      plist({
        apiKey: 'api-key',
        bundleId: 'com.kathelix.catvox.dev',
        appId: '1:123:ios:abc',
        projectId: 'catvox-dev',
      })
    );

    assert.throws(
      () => runValidator(file, { CATVOX_FIREBASE_APP_ID: 'replace-with-app-id' }),
      (error) => {
        assert.match(error.stderr.toString(), /CATVOX_FIREBASE_APP_ID/);
        return true;
      }
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
