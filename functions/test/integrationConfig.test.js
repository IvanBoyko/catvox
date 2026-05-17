const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');

const {
  argValue,
  assertMutationGateAllowed,
  configValue,
  isPlaceholder,
  loadEnvFile,
  normalize,
  parseList,
  requiredConfigValue,
  stripQuotes,
} = require('../lib-integration/integration/config.js');

function sorted(set) {
  return Array.from(set).sort();
}

test('mutation gate allows confirmed mutable runs for integration-safe environments', () => {
  assert.doesNotThrow(() => {
    assertMutationGateAllowed({
      confirmed: true,
      mutationsAllowed: true,
      environmentName: 'dev',
      integrationSafeEnvironments: new Set(['dev', 'staging']),
    });
  });
});

test('mutation gate rejects missing confirmation flag', () => {
  assert.throws(
    () => assertMutationGateAllowed({
      confirmed: false,
      mutationsAllowed: true,
      environmentName: 'dev',
      integrationSafeEnvironments: new Set(['dev']),
    }),
    /without --confirm and CATVOX_INTEGRATION_MUTATIONS_ALLOWED=1/
  );
});

test('mutation gate rejects missing mutation opt-in', () => {
  assert.throws(
    () => assertMutationGateAllowed({
      confirmed: true,
      mutationsAllowed: false,
      environmentName: 'dev',
      integrationSafeEnvironments: new Set(['dev']),
    }),
    /without --confirm and CATVOX_INTEGRATION_MUTATIONS_ALLOWED=1/
  );
});

test('mutation gate rejects environments outside the integration-safe allowlist', () => {
  assert.throws(
    () => assertMutationGateAllowed({
      confirmed: true,
      mutationsAllowed: true,
      environmentName: 'prod',
      integrationSafeEnvironments: new Set(['dev']),
    }),
    /CATVOX_ENVIRONMENT=prod/
  );
});

test('mutation gate rejects empty integration-safe allowlists', () => {
  assert.throws(
    () => assertMutationGateAllowed({
      confirmed: true,
      mutationsAllowed: true,
      environmentName: 'dev',
      integrationSafeEnvironments: new Set(),
    }),
    /CATVOX_ENVIRONMENT=dev/
  );
});

test('parseList trims entries and drops empty items', () => {
  assert.deepEqual(sorted(parseList('dev')), ['dev']);
  assert.deepEqual(sorted(parseList('dev,staging')), ['dev', 'staging']);
  assert.deepEqual(sorted(parseList(' dev , staging ')), ['dev', 'staging']);
  assert.deepEqual(sorted(parseList('dev,,staging')), ['dev', 'staging']);
  assert.deepEqual(sorted(parseList('')), []);
});

test('loadEnvFile reads simple values without overwriting existing env', () => {
  const dir = mkdtempSync(join(tmpdir(), 'catvox-env-'));
  const envFile = join(dir, 'integration.env');
  const env = {
    EXISTING: 'from-process',
  };

  try {
    writeFileSync(
      envFile,
      [
        '# comment',
        '',
        'SIMPLE=value',
        'DOUBLE_QUOTED="quoted value"',
        "SINGLE_QUOTED='single quoted'",
        'NO_EQUALS',
        'EXISTING=from-file',
        ' SPACED_KEY = spaced ',
      ].join('\n')
    );

    loadEnvFile(envFile, env);

    assert.equal(env.SIMPLE, 'value');
    assert.equal(env.DOUBLE_QUOTED, 'quoted value');
    assert.equal(env.SINGLE_QUOTED, 'single quoted');
    assert.equal(env.NO_EQUALS, undefined);
    assert.equal(env.EXISTING, 'from-process');
    assert.equal(env.SPACED_KEY, 'spaced');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('loadEnvFile ignores missing path values', () => {
  const env = {};
  loadEnvFile('', env);
  loadEnvFile(undefined, env);
  assert.deepEqual(env, {});
});

test('argValue supports --name=value and --name value forms', () => {
  assert.equal(argValue(['--env-file=dev.env'], '--env-file'), 'dev.env');
  assert.equal(argValue(['--env-file', 'dev.env'], '--env-file'), 'dev.env');
  assert.equal(argValue(['--skip-log'], '--env-file'), undefined);
});

test('config value helpers trim values and support aliases', () => {
  const env = {
    PRIMARY: '  primary ',
    ALIAS: 'alias',
    BLANK: '   ',
  };

  assert.equal(normalize(' value '), 'value');
  assert.equal(normalize('   '), undefined);
  assert.equal(stripQuotes('"quoted"'), 'quoted');
  assert.equal(stripQuotes("'quoted'"), 'quoted');
  assert.equal(configValue(env, 'BLANK', 'ALIAS'), 'alias');
  assert.equal(requiredConfigValue(env, 'PRIMARY'), 'primary');
  assert.throws(
    () => requiredConfigValue(env, 'MISSING', 'ALSO_MISSING'),
    /MISSING or ALSO_MISSING/
  );
});

test('placeholder helper rejects generated config placeholder patterns', () => {
  assert.equal(isPlaceholder('replace-with-dev-firebase-app-id'), true);
  assert.equal(isPlaceholder('$(CATVOX_FIREBASE_APP_ID)'), true);
  assert.equal(isPlaceholder('<firebase-app-id>'), true);
  assert.equal(isPlaceholder('TODO'), true);
  assert.equal(isPlaceholder('1:99523926611:ios:9b3848f13783e1c585c4a6'), false);
  assert.equal(isPlaceholder('AIza-real-looking-key'), false);
});

test('required config value rejects placeholders before downstream network calls', () => {
  assert.throws(
    () => requiredConfigValue({ APP_ID: 'replace-with-dev-firebase-app-id' }, 'APP_ID'),
    /Invalid placeholder integration configuration/
  );
});
