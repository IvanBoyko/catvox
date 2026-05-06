import { Firestore } from '@google-cloud/firestore';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const DEFAULT_PROJECT_ID = 'kathelix-catvox-prod';
const DEFAULT_SIGNED_URL_ENDPOINT =
  'https://getsigneduploadurl-pdkw5uifga-uc.a.run.app/';
const DEFAULT_ANALYSE_ENDPOINT =
  'https://analysevideo-pdkw5uifga-uc.a.run.app/';
const DEFAULT_FIREBASE_APP_ID = '1:953500951129:ios:1595a4c27cd8f3f7964748';
const DEFAULT_FIREBASE_API_KEY = 'AIzaSyAMKDQ_mIGQWQF4VhU8lytvvGx1TpuoBMI';
const DEFAULT_IOS_BUNDLE_ID = 'com.kathelix.catvox';

type AppCheckUnauthorizedResponseBody = {
  code?: unknown;
  message?: unknown;
};

type QuotaResponseBody = {
  code?: unknown;
  message?: unknown;
  limit?: unknown;
  remaining?: unknown;
  resetAt?: unknown;
};

type AppCheckExchangeResponse = {
  token?: unknown;
  ttl?: unknown;
};

type LogEntry = {
  timestamp?: string;
  jsonPayload?: {
    endpoint?: unknown;
    limit?: unknown;
    remaining?: unknown;
    resetAt?: unknown;
  };
};

type UTCQuotaWindow = {
  usageDate: string;
  resetAt: string;
};

const args = new Set(process.argv.slice(2));
const confirmed = args.has('--confirm');
const skipLog = args.has('--skip-log');

const projectId =
  process.env.CATVOX_PROJECT_ID ||
  process.env.GCP_PROJECT_ID ||
  process.env.GCLOUD_PROJECT ||
  DEFAULT_PROJECT_ID;
const signedUrlEndpoint =
  process.env.CATVOX_SIGNED_URL_ENDPOINT || DEFAULT_SIGNED_URL_ENDPOINT;
const analyseEndpoint =
  process.env.CATVOX_ANALYSE_ENDPOINT || DEFAULT_ANALYSE_ENDPOINT;
const firebaseAppId =
  process.env.CATVOX_FIREBASE_APP_ID || DEFAULT_FIREBASE_APP_ID;
const firebaseApiKey =
  process.env.CATVOX_FIREBASE_API_KEY || DEFAULT_FIREBASE_API_KEY;
const iosBundleId =
  process.env.CATVOX_IOS_BUNDLE_ID || DEFAULT_IOS_BUNDLE_ID;
const rawAppCheckDebugToken =
  process.env.CATVOX_APP_CHECK_DEBUG_TOKEN ||
  process.env.TF_VAR_app_check_debug_token ||
  '';
const appCheckDebugToken = rawAppCheckDebugToken.trim();

function usage(): void {
  console.error(`
Usage:
  npm --prefix functions run test:integration

Options:
  --confirm   Required. Writes and deletes a temporary Firestore usage doc.
  --skip-log  Verify only the HTTP response, not the Cloud Logging entry.

Environment:
  CATVOX_PROJECT_ID             Defaults to ${DEFAULT_PROJECT_ID}
  CATVOX_SIGNED_URL_ENDPOINT    Defaults to ${DEFAULT_SIGNED_URL_ENDPOINT}
  CATVOX_ANALYSE_ENDPOINT        Defaults to ${DEFAULT_ANALYSE_ENDPOINT}
  CATVOX_APP_CHECK_DEBUG_TOKEN  Required. Registered Firebase App Check debug token.
  CATVOX_FIREBASE_APP_ID        Defaults to ${DEFAULT_FIREBASE_APP_ID}
  CATVOX_FIREBASE_API_KEY       Defaults to committed iOS Firebase API key.
  CATVOX_IOS_BUNDLE_ID          Defaults to ${DEFAULT_IOS_BUNDLE_ID}
`);
}

function currentUTCQuotaWindow(now = new Date()): UTCQuotaWindow {
  const resetAt = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + 1,
    0,
    0,
    0,
    0
  )).toISOString().replace('.000Z', 'Z');

  return {
    usageDate: now.toISOString().slice(0, 10),
    resetAt,
  };
}

function secondsUntil(resetAt: string, now = new Date()): number {
  return Math.ceil((Date.parse(resetAt) - now.getTime()) / 1000);
}

function assert(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function parseJsonResponse<T>(rawBody: string, label: string): T {
  try {
    return JSON.parse(rawBody) as T;
  } catch {
    throw new Error(`${label} response body was not JSON: ${rawBody}`);
  }
}

function parseQuotaResponse(rawBody: string): QuotaResponseBody {
  return parseJsonResponse<QuotaResponseBody>(rawBody, 'Quota contract');
}

function fingerprintSecret(value: string): string {
  return createHash('sha256').update(value).digest('hex').slice(0, 12);
}

function describeDebugToken(): string {
  if (!appCheckDebugToken) {
    return 'missing';
  }

  const trimmedNote =
    rawAppCheckDebugToken === appCheckDebugToken ? '' : ', trimmed surrounding whitespace';

  return `sha256:${fingerprintSecret(appCheckDebugToken)} length:${appCheckDebugToken.length}${trimmedNote}`;
}

async function exchangeDebugTokenForAppCheckToken(): Promise<string> {
  if (!appCheckDebugToken) {
    throw new Error(
      'CATVOX_APP_CHECK_DEBUG_TOKEN is required for App Check-protected integration tests'
    );
  }

  const app = `projects/${projectId}/apps/${firebaseAppId}`;
  const url =
    `https://firebaseappcheck.googleapis.com/v1/${app}:exchangeDebugToken` +
    `?key=${encodeURIComponent(firebaseApiKey)}`;
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Ios-Bundle-Identifier': iosBundleId,
    },
    body: JSON.stringify({
      debugToken: appCheckDebugToken,
      limitedUse: false,
    }),
  });

  const rawBody = await response.text();
  if (!response.ok) {
    throw new Error(
      [
        `Failed to exchange App Check debug token: HTTP ${response.status} ${rawBody}`,
        `Debug token fingerprint: ${describeDebugToken()}`,
        `Firebase app: projects/${projectId}/apps/${firebaseAppId}`,
        `iOS bundle identifier: ${iosBundleId}`,
        'Verify that this exact debug token is registered for the Firebase iOS app above.',
      ].join('\n')
    );
  }

  const parsed = JSON.parse(rawBody) as AppCheckExchangeResponse;
  if (typeof parsed.token !== 'string' || parsed.token.length === 0) {
    throw new Error(`App Check token exchange response was missing token: ${rawBody}`);
  }

  return parsed.token;
}

async function verifyAppCheckUnauthorized(
  endpointName: string,
  endpoint: string,
  body: Record<string, unknown>
): Promise<void> {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  const rawBody = await response.text();
  const parsed = parseJsonResponse<AppCheckUnauthorizedResponseBody>(
    rawBody,
    `${endpointName} App Check`
  );
  const contentType = response.headers.get('content-type') || '';

  assert(
    response.status === 401,
    `Expected ${endpointName} without App Check to return HTTP 401, got ${response.status}`
  );
  assert(
    contentType.includes('application/json'),
    `Expected ${endpointName} App Check rejection to be JSON, got ${contentType || '(missing)'}`
  );
  assert(
    parsed.code === 'app_check_unauthorized',
    `Expected ${endpointName} app_check_unauthorized code, got ${String(parsed.code)}`
  );

  console.log(`${endpointName} App Check unauthenticated rejection verified`);
}

async function verifyAppCheckUnauthorizedPreflight(testUserId: string): Promise<void> {
  await verifyAppCheckUnauthorized(
    'getSignedUploadURL',
    signedUrlEndpoint,
    {
      filename: 'app-check-preflight.mov',
      contentType: 'video/quicktime',
      userId: testUserId,
    }
  );

  await verifyAppCheckUnauthorized(
    'analyseVideo',
    analyseEndpoint,
    {
      gcsUri: `gs://catvox-raw-videos-${projectId}/app-check-preflight.mov`,
      userId: testUserId,
    }
  );
}

async function verifyHttpContract(
  testUserId: string,
  expectedResetAt: string,
  appCheckToken: string
): Promise<QuotaResponseBody> {
  const response = await fetch(signedUrlEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Firebase-AppCheck': appCheckToken,
    },
    body: JSON.stringify({
      filename: 'quota-contract-test.mov',
      contentType: 'video/quicktime',
      userId: testUserId,
    }),
  });

  const rawBody = await response.text();
  const body = parseQuotaResponse(rawBody);
  const retryAfter = response.headers.get('retry-after');
  const contentType = response.headers.get('content-type') || '';
  const retryAfterSeconds = Number(retryAfter);
  const expectedRetryAfterSeconds = secondsUntil(expectedResetAt);

  assert(response.status === 429, `Expected HTTP 429, got ${response.status}`);
  assert(
    contentType.includes('application/json'),
    `Expected JSON content-type, got ${contentType || '(missing)'}`
  );
  assert(
    /^[1-9]\d*$/.test(retryAfter || ''),
    `Expected positive integer Retry-After, got ${retryAfter || '(missing)'}`
  );
  assert(
    Math.abs(retryAfterSeconds - expectedRetryAfterSeconds) <= 60,
    `Expected Retry-After near ${expectedRetryAfterSeconds}s, got ${retryAfterSeconds}s`
  );
  assert(
    body.code === 'daily_scan_quota_exceeded',
    `Expected daily_scan_quota_exceeded code, got ${String(body.code)}`
  );
  assert(body.limit === 5, `Expected limit 5, got ${String(body.limit)}`);
  assert(body.remaining === 0, `Expected remaining 0, got ${String(body.remaining)}`);
  assert(
    body.resetAt === expectedResetAt,
    `Expected resetAt ${expectedResetAt}, got ${String(body.resetAt)}`
  );

  console.log('HTTP contract verified:', JSON.stringify(body));
  console.log('Retry-After:', retryAfter);

  return body;
}

function parseLogEntries(stdout: string): LogEntry[] {
  const parsed = JSON.parse(stdout || '[]') as unknown;
  assert(Array.isArray(parsed), 'gcloud logging read did not return an array');
  return parsed as LogEntry[];
}

function readQuotaLogs(startTime: Date): LogEntry[] {
  const filter = [
    'resource.type="cloud_run_revision"',
    'resource.labels.service_name="getsigneduploadurl"',
    'jsonPayload.event="quota_exceeded"',
    'jsonPayload.quotaType="daily_scan"',
    `timestamp>="${startTime.toISOString()}"`,
  ].join(' AND ');

  const result = spawnSync(
    'gcloud',
    [
      'logging',
      'read',
      filter,
      `--project=${projectId}`,
      '--limit=10',
      '--freshness=10m',
      '--format=json',
    ],
    { encoding: 'utf8' }
  );

  if (result.error) {
    throw result.error;
  }

  const stderr = typeof result.stderr === 'string' ? result.stderr : '';
  if (result.status !== 0) {
    throw new Error(stderr || 'gcloud logging read failed');
  }

  const stdout = typeof result.stdout === 'string' ? result.stdout : '';
  return parseLogEntries(stdout);
}

async function verifyStructuredLog(expectedResetAt: unknown, startTime: Date): Promise<void> {
  for (let attempt = 1; attempt <= 6; attempt += 1) {
    const entries = readQuotaLogs(startTime);
    const match = entries.find((entry) => {
      const payload = entry.jsonPayload || {};
      return payload.endpoint === 'getSignedUploadURL' &&
        payload.limit === 5 &&
        payload.remaining === 0 &&
        payload.resetAt === expectedResetAt;
    });

    if (match) {
      console.log('Structured log verified:', match.timestamp);
      return;
    }

    await new Promise((resolve) => setTimeout(resolve, 3000));
  }

  throw new Error('No matching quota_exceeded structured log found');
}

async function main(): Promise<void> {
  if (!confirmed) {
    usage();
    throw new Error('Refusing to touch backend data without --confirm');
  }

  const testUserId = `quota-contract-test-${Date.now()}`;
  const startTime = new Date(Date.now() - 1000);
  const quotaWindow = currentUTCQuotaWindow();
  const firestore = new Firestore({ projectId });
  const doc = firestore.collection('usage').doc(testUserId);

  console.log('Project:', projectId);
  console.log('Signed URL endpoint:', signedUrlEndpoint);
  console.log('Analyse endpoint:', analyseEndpoint);
  console.log('Temporary userId:', testUserId);
  console.log('App Check debug token:', describeDebugToken());

  let quotaDocCreated = false;
  try {
    const appCheckToken = await exchangeDebugTokenForAppCheckToken();
    console.log('App Check debug token exchanged');

    await verifyAppCheckUnauthorizedPreflight(testUserId);

    await doc.set({
      count: 5,
      lastResetDate: quotaWindow.usageDate,
    });
    quotaDocCreated = true;
    console.log('Temporary Firestore quota doc created');

    const body = await verifyHttpContract(
      testUserId,
      quotaWindow.resetAt,
      appCheckToken
    );

    if (skipLog) {
      console.log('Structured log verification skipped');
    } else {
      await verifyStructuredLog(body.resetAt, startTime);
    }
  } finally {
    if (quotaDocCreated) {
      await doc.delete().catch((err: unknown) => {
        console.error('Failed to delete temporary Firestore doc:', err);
      });
      console.log('Temporary Firestore quota doc deleted');
    }
    await firestore.terminate();
  }
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
