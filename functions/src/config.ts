const DEFAULT_FUNCTION_REGION = 'us-central1';
const DEFAULT_BACKEND_SERVICE_ACCOUNT_NAME = 'catvox-backend-sa';

type Environment = NodeJS.ProcessEnv;

export function configuredProjectId(env: Environment = process.env): string | undefined {
  return firstValue(env.CATVOX_PROJECT_ID, firebaseConfigProjectId(env));
}

export function requiredProjectId(env: Environment = process.env): string {
  const projectId = configuredProjectId(env);
  if (!projectId) {
    throw new Error(
      'Project ID is not configured. Set CATVOX_PROJECT_ID or deploy with Firebase project metadata.'
    );
  }

  return projectId;
}

export function functionRegion(env: Environment = process.env): string {
  return firstValue(env.CATVOX_FUNCTION_REGION, env.FUNCTION_REGION) ??
    DEFAULT_FUNCTION_REGION;
}

export function vertexLocation(env: Environment = process.env): string {
  return firstValue(env.CATVOX_VERTEX_LOCATION) ?? functionRegion(env);
}

export function backendServiceAccount(
  env: Environment = process.env
): string | undefined {
  const explicit = firstValue(env.CATVOX_BACKEND_SERVICE_ACCOUNT);
  if (explicit) {
    return explicit;
  }

  const projectId = configuredProjectId(env);
  if (!projectId) {
    return undefined;
  }

  const accountName =
    firstValue(env.CATVOX_BACKEND_SERVICE_ACCOUNT_NAME) ??
    DEFAULT_BACKEND_SERVICE_ACCOUNT_NAME;

  return `${accountName}@${projectId}.iam.gserviceaccount.com`;
}

export function backendServiceAccountOption(
  env: Environment = process.env
): { serviceAccount?: string } {
  const serviceAccount = backendServiceAccount(env);
  if (serviceAccount) {
    return { serviceAccount };
  }

  if (firstValue(env.CATVOX_ALLOW_DEFAULT_SERVICE_ACCOUNT) === '1') {
    return {};
  }

  throw new Error(
    'Backend service account is not configured. Set CATVOX_BACKEND_SERVICE_ACCOUNT, ' +
    'CATVOX_PROJECT_ID, or Firebase project metadata. To intentionally use the ' +
    'platform default service account, set CATVOX_ALLOW_DEFAULT_SERVICE_ACCOUNT=1.'
  );
}

function firebaseConfigProjectId(env: Environment): string | undefined {
  const rawConfig = firstValue(env.FIREBASE_CONFIG);
  if (!rawConfig) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(rawConfig) as { projectId?: unknown };
    return typeof parsed.projectId === 'string' ? parsed.projectId : undefined;
  } catch {
    return undefined;
  }
}

function firstValue(...values: Array<string | undefined>): string | undefined {
  for (const value of values) {
    const normalized = normalize(value);
    if (normalized) {
      return normalized;
    }
  }

  return undefined;
}

function normalize(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}
