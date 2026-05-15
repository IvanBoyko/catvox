const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');

const script = join(__dirname, '..', '..', 'scripts', 'lib', 'read-xcconfig-value.sh');

function readValue(file, key) {
  return execFileSync('bash', [script, file, key], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function assertReadFails(file, key, pattern) {
  assert.throws(
    () => readValue(file, key),
    (error) => {
      assert.equal(error.status, 2);
      assert.match(error.stderr.toString(), pattern);
      return true;
    }
  );
}

test('read-xcconfig-value reads present keys and trims whitespace', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-xcconfig-'));
  const file = join(dir, 'test.xcconfig');

  try {
    writeFileSync(
      file,
      [
        'PLAIN_KEY = plain',
        '  WHITESPACE_KEY   =   spaced value   ',
      ].join('\n')
    );

    assert.equal(readValue(file, 'PLAIN_KEY'), 'plain\n');
    assert.equal(readValue(file, 'WHITESPACE_KEY'), 'spaced value\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('read-xcconfig-value returns nothing for missing keys and files', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-xcconfig-'));
  const file = join(dir, 'test.xcconfig');

  try {
    writeFileSync(file, 'PRESENT = value\n');

    assert.equal(readValue(file, 'MISSING'), '');
    assert.equal(readValue(join(dir, 'missing.xcconfig'), 'PRESENT'), '');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('read-xcconfig-value ignores commented lines', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-xcconfig-'));
  const file = join(dir, 'test.xcconfig');

  try {
    writeFileSync(
      file,
      [
        '// COMMENTED_KEY = commented',
        'COMMENTED_KEY = active',
      ].join('\n')
    );

    assert.equal(readValue(file, 'COMMENTED_KEY'), 'active\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('read-xcconfig-value rejects URL schemes in host fields', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-xcconfig-'));
  const file = join(dir, 'test.xcconfig');

  try {
    writeFileSync(
      file,
      [
        'CATVOX_SIGNED_UPLOAD_URL_HOST = https://example.com',
        'CATVOX_POSTHOG_HOST_NAME = https://us.i.posthog.com',
      ].join('\n')
    );

    assertReadFails(file, 'CATVOX_SIGNED_UPLOAD_URL_HOST', /must be a hostname only/);
    assertReadFails(file, 'CATVOX_POSTHOG_HOST_NAME', /must be a hostname only/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('read-xcconfig-value allows host-only host fields', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-xcconfig-'));
  const file = join(dir, 'test.xcconfig');

  try {
    writeFileSync(
      file,
      [
        'CATVOX_SIGNED_UPLOAD_URL_HOST = getsigneduploadurl.example.com',
        'CATVOX_POSTHOG_HOST_NAME = us.i.posthog.com',
      ].join('\n')
    );

    assert.equal(
      readValue(file, 'CATVOX_SIGNED_UPLOAD_URL_HOST'),
      'getsigneduploadurl.example.com\n'
    );
    assert.equal(readValue(file, 'CATVOX_POSTHOG_HOST_NAME'), 'us.i.posthog.com\n');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
