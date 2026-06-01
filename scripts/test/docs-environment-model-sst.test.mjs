// Doc single-source-of-truth contract for the environment model (issue #103).
// Asserts docs/TRD.md carries the canonical "Environment Model" section, that the
// section documents the security-tier keys/literals plus the no-source-change
// lifecycle guarantee, and that the living docs (HLD, the create-environment
// runbook, terraform/README) point to it instead of restating the rules. Run with
// `make scripts-test` or
// `node --test scripts/test/docs-environment-model-sst.test.mjs`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

function read(relPath) {
  return readFileSync(resolve(repoRoot, relPath), 'utf8');
}

// Extract the canonical "Environment Model" top-level section from TRD by heading
// text — number-agnostic, so renumbering the document never breaks this check.
function environmentModelSection(trd) {
  const lines = trd.split('\n');
  const start = lines.findIndex((line) =>
    /^##\s+(?:\d+\.\s+)?Environment Model\s*$/.test(line)
  );
  assert.notEqual(
    start,
    -1,
    'docs/TRD.md must contain a top-level "Environment Model" section'
  );
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^##\s+/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join('\n');
}

test('docs/TRD.md has the canonical Environment Model section', () => {
  environmentModelSection(read('docs/TRD.md')); // throws if absent
});

test('the Environment Model section documents every security-tier difference (AC4)', () => {
  const section = environmentModelSection(read('docs/TRD.md'));
  // The config keys whose tier behaviour the validator enforces must all appear,
  // so a reviewer can determine every mutable-vs-protected difference from the
  // section alone. Keep in sync with scripts/validate-environment-config.mjs.
  for (const key of [
    'CATVOX_ENVIRONMENT_PROTECTED',
    'CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT',
    'CATVOX_GCP_WIF_GITHUB_REF',
    'CATVOX_FIREBASE_IOS_APP_DELETION_POLICY',
    'CATVOX_INTEGRATION_SAFE_ENVIRONMENTS',
  ]) {
    assert.ok(section.includes(key), `Environment Model section must mention ${key}`);
  }
  for (const literal of ['ENFORCED', 'UNENFORCED', 'ABANDON']) {
    assert.ok(section.includes(literal), `Environment Model section must mention ${literal}`);
  }
  assert.match(section, /mutable/i);
  assert.match(section, /protected/i);
});

test('the Environment Model section states the no-source-change lifecycle (AC3)', () => {
  const section = environmentModelSection(read('docs/TRD.md'));
  assert.match(section, /source-code change/i);
});

test('the living docs point to the Environment Model section instead of restating it (AC2)', () => {
  for (const relPath of [
    'docs/HLD.md',
    'docs/CREATE_NEW_ENVIRONMENT.md',
    'terraform/README.md',
  ]) {
    const body = read(relPath);
    assert.ok(
      body.includes('Environment Model section'),
      `${relPath} must point to the "Environment Model section"`
    );
    assert.ok(body.includes('TRD.md'), `${relPath} must reference docs/TRD.md`);
  }
});
