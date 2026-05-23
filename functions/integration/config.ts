import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

type Environment = Record<string, string | undefined>;

export type MutationGate = {
  confirmed: boolean;
  mutationsAllowed: boolean;
  environmentName: string;
  integrationSafeEnvironments: Set<string>;
};

const placeholderHelperPath = [
  join(__dirname, '../../../scripts/lib/config-placeholders.cjs'),
  join(__dirname, '../../scripts/lib/config-placeholders.cjs'),
].find((candidate) => existsSync(candidate));

if (!placeholderHelperPath) {
  throw new Error('Unable to locate scripts/lib/config-placeholders.cjs');
}

const placeholderHelpers = require(placeholderHelperPath) as {
  isPlaceholder(value: string): boolean;
};

export const { isPlaceholder } = placeholderHelpers;

export function configValue(env: Environment, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = normalize(env[key]);
    if (value) {
      return value;
    }
  }

  return undefined;
}

export function requiredConfigValue(
  env: Environment,
  primaryKey: string,
  ...aliasKeys: string[]
): string {
  const value = configValue(env, primaryKey, ...aliasKeys);
  if (!value) {
    throw new Error(
      `Missing required integration configuration: ${[primaryKey, ...aliasKeys].join(' or ')}`
    );
  }

  if (isPlaceholder(value)) {
    throw new Error(
      `Invalid placeholder integration configuration for ${[primaryKey, ...aliasKeys].join(' or ')}`
    );
  }

  return value;
}

export function argValue(argv: string[], name: string): string | undefined {
  const prefix = `${name}=`;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value.startsWith(prefix)) {
      return value.slice(prefix.length);
    }
    if (value === name) {
      return argv[index + 1];
    }
  }

  return undefined;
}

export function loadEnvFile(path: string | undefined, env: Environment = process.env): void {
  const normalizedPath = normalize(path);
  if (!normalizedPath) {
    return;
  }

  for (const line of readFileSync(normalizedPath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) {
      continue;
    }

    const separator = trimmed.indexOf('=');
    if (separator === -1) {
      continue;
    }

    const key = trimmed.slice(0, separator).trim();
    const value = stripQuotes(trimmed.slice(separator + 1).trim());
    if (key && env[key] === undefined) {
      env[key] = value;
    }
  }
}

export function parseList(value: string): Set<string> {
  return new Set(
    value
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item.length > 0)
  );
}

export function isIntegrationSafeEnvironment(
  environmentName: string,
  integrationSafeEnvironments: Set<string>
): boolean {
  const normalizedEnvironmentName = normalize(environmentName);
  if (!normalizedEnvironmentName) {
    return false;
  }

  return integrationSafeEnvironments.has(normalizedEnvironmentName);
}

export function normalize(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export function stripQuotes(value: string): string {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }

  return value;
}

export function assertMutationGateAllowed(gate: MutationGate): void {
  if (!gate.confirmed || !gate.mutationsAllowed) {
    throw new Error(
      'Refusing to touch backend data without --confirm and CATVOX_INTEGRATION_MUTATIONS_ALLOWED=1'
    );
  }

  if (!isIntegrationSafeEnvironment(gate.environmentName, gate.integrationSafeEnvironments)) {
    throw new Error(
      `Refusing to touch backend data for CATVOX_ENVIRONMENT=${gate.environmentName}. ` +
      'Add it to CATVOX_INTEGRATION_SAFE_ENVIRONMENTS only for environments that are safe for mutable tests.'
    );
  }
}
