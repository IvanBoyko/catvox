#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import placeholderHelpers from './lib/config-placeholders.cjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..');
const { isPlaceholder } = placeholderHelpers;

const environmentName = requiredEnv('CATVOX_ENVIRONMENT');
const projectId = requiredEnv('CATVOX_PROJECT_ID');
const firebaseAppId = requiredEnv('CATVOX_FIREBASE_APP_ID');
const firebaseApiKey = requiredEnv('CATVOX_FIREBASE_API_KEY');
const bundleId = requiredEnv('CATVOX_IOS_BUNDLE_ID');
const plistPath = resolve(
  repoRoot,
  process.env.CATVOX_FIREBASE_PLIST_PATH ||
    `CatVox/Resources/Firebase/GoogleService-Info-${environmentName}.plist`
);

const entries = parsePlistStrings(readFileSync(plistPath, 'utf8'));

assertPlistValue(entries, 'PROJECT_ID', projectId);
assertPlistValue(entries, 'GOOGLE_APP_ID', firebaseAppId);
assertPlistValue(entries, 'API_KEY', firebaseApiKey);
assertPlistValue(entries, 'BUNDLE_ID', bundleId);

console.log(`Firebase iOS config validated for ${environmentName}: ${plistPath}`);

function requiredEnv(name) {
  const value = normalize(process.env[name]);
  if (!value || isPlaceholder(value)) {
    throw new Error(`${name} is required and must not be a placeholder`);
  }
  return value;
}

function assertPlistValue(entries, key, expected) {
  const actual = normalize(entries.get(key));
  if (actual !== expected) {
    throw new Error(
      `Firebase plist mismatch for ${key}: expected ${expected}, got ${actual || '(missing)'}`
    );
  }
}

function parsePlistStrings(xml) {
  const entries = new Map();
  const pattern = /<key>([^<]+)<\/key>\s*<(string|true|false)>([^<]*)<\/\2>|<key>([^<]+)<\/key>\s*<(true|false)\s*\/>/g;
  let match;
  while ((match = pattern.exec(xml)) !== null) {
    const key = decodeXml(match[1] || match[4]);
    const value =
      match[2] === 'true' || match[5] === 'true'
        ? 'true'
        : match[2] === 'false' || match[5] === 'false'
          ? 'false'
          : decodeXml(match[3] || '');
    entries.set(key, value);
  }
  return entries;
}

function normalize(value) {
  if (value === undefined || value === null) {
    return undefined;
  }
  const trimmed = String(value).trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function decodeXml(value) {
  return value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
}
