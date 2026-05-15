const DEFAULT_FUNCTION_REGION = 'us-central1';
const DEFAULT_BACKEND_SERVICE_ACCOUNT_NAME = 'catvox-backend-sa';

type Environment = NodeJS.ProcessEnv;

export function configuredProjectId(env: Environment = process.env): string | undefined {
  return firstValue(env.CATVOX_PROJECT_ID, env.GCP_PROJECT_ID, env.GCLOUD_PROJECT);
}

export function requiredProjectId(env: Environment = process.env): string {
  const projectId = configuredProjectId(env);
  if (!projectId) {
    throw new Error(
      'Project ID is not configured. Set CATVOX_PROJECT_ID, GCP_PROJECT_ID, or GCLOUD_PROJECT.'
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
  return serviceAccount ? { serviceAccount } : {};
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
