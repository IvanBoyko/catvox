import { FieldValue, Firestore, Timestamp } from '@google-cloud/firestore';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  argValue,
  assertMutationGateAllowed,
  configValue,
  loadEnvFile,
  parseList,
  requiredConfigValue,
} from './config';

const DAILY_LIMIT = 5;
const RESERVATION_TTL_MS = 5 * 60 * 1000;
const LIMIT_EXCEEDED = 'LIMIT_EXCEEDED';
const RESERVATION_ALREADY_EXISTS = 'RESERVATION_ALREADY_EXISTS';

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

type ReservationRecord = {
  expiresAt?: unknown;
};

type ActiveReservations = Record<string, ReservationRecord>;

const rawArgs = process.argv.slice(2);
const args = new Set(rawArgs);
loadEnvFile(argValue(rawArgs, '--env-file') || process.env.CATVOX_INTEGRATION_ENV_FILE);

if (args.has('-h') || args.has('--help') || args.has('help')) {
  usage();
  process.exit(0);
}

const confirmed = args.has('--confirm');
const skipLog = args.has('--skip-log');
const mutationsAllowed = configValue(process.env, 'CATVOX_INTEGRATION_MUTATIONS_ALLOWED') === '1';

const environmentName = requiredConfigValue(process.env, 'CATVOX_ENVIRONMENT');
const integrationSafeEnvironments = parseList(
  configValue(process.env, 'CATVOX_INTEGRATION_SAFE_ENVIRONMENTS') ?? 'dev'
);
const projectId = requiredConfigValue(
  process.env,
  'CATVOX_PROJECT_ID',
  'GCP_PROJECT_ID',
  'GCLOUD_PROJECT'
);
const signedUrlEndpoint = requiredConfigValue(
  process.env,
  'CATVOX_SIGNED_UPLOAD_URL_ENDPOINT',
  'CATVOX_SIGNED_URL_ENDPOINT'
);
const analyseEndpoint = requiredConfigValue(
  process.env,
  'CATVOX_ANALYSE_VIDEO_ENDPOINT',
  'CATVOX_ANALYSE_ENDPOINT'
);
const firebaseAppId = requiredConfigValue(process.env, 'CATVOX_FIREBASE_APP_ID');
const firebaseApiKey = requiredConfigValue(process.env, 'CATVOX_FIREBASE_API_KEY');
const iosBundleId = requiredConfigValue(process.env, 'CATVOX_IOS_BUNDLE_ID');
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
  --confirm   Required. Writes and deletes temporary Firestore usage docs.
  --skip-log  Verify only the HTTP response, not the Cloud Logging entry.
  --env-file  Optional. Loads KEY=value lines before reading configuration.

Environment:
  CATVOX_ENVIRONMENT                       Required. Environment name; must be integration-safe.
  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS     Comma-separated mutation-safe env names. Defaults to dev.
  CATVOX_INTEGRATION_MUTATIONS_ALLOWED=1  Required for Firestore-mutating tests.
  CATVOX_PROJECT_ID                        Required. GCP/Firebase project ID.
  CATVOX_SIGNED_UPLOAD_URL_ENDPOINT        Required. getSignedUploadURL endpoint.
  CATVOX_ANALYSE_VIDEO_ENDPOINT            Required. analyseVideo endpoint.
  CATVOX_APP_CHECK_DEBUG_TOKEN             Required. Registered Firebase App Check debug token.
  CATVOX_FIREBASE_APP_ID                   Required. Firebase iOS app ID.
  CATVOX_FIREBASE_API_KEY                  Required. Firebase web API key for App Check exchange.
  CATVOX_IOS_BUNDLE_ID                     Required. Firebase iOS bundle ID.
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

function normalizedCount(value: unknown): number {
  return typeof value === 'number' && Number.isInteger(value) && value > 0
    ? value
    : 0;
}

function normalizedReservations(value: unknown): ActiveReservations {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return {};
  }

  const reservations: ActiveReservations = {};

  for (const [id, reservation] of Object.entries(value)) {
    if (typeof reservation === 'object' && reservation !== null && !Array.isArray(reservation)) {
      reservations[id] = reservation as ReservationRecord;
    }
  }

  return reservations;
}

function timestampLikeToMillis(value: unknown): number | null {
  if (value instanceof Timestamp) {
    return value.toMillis();
  }

  if (value instanceof Date) {
    return value.getTime();
  }

  if (
    typeof value === 'object' &&
    value !== null &&
    'toMillis' in value &&
    typeof value.toMillis === 'function'
  ) {
    const millis = value.toMillis() as unknown;
    return typeof millis === 'number' && Number.isFinite(millis) ? millis : null;
  }

  return null;
}

function summarizeIntegrationUsageQuota(
  data: Record<string, unknown>,
  today: string,
  nowMs: number
): {
  count: number;
  activeReservations: ActiveReservations;
  expiredReservationIds: string[];
  usedSlots: number;
} {
  const isNewDay = data.lastResetDate !== today;
  const count = isNewDay ? 0 : normalizedCount(data.count);
  const reservations = normalizedReservations(data.reservations);
  const activeReservations: ActiveReservations = {};
  const expiredReservationIds: string[] = [];

  for (const [id, reservation] of Object.entries(reservations)) {
    const expiresAtMs = timestampLikeToMillis(reservation.expiresAt);

    if (expiresAtMs !== null && expiresAtMs > nowMs) {
      activeReservations[id] = reservation;
    } else {
      expiredReservationIds.push(id);
    }
  }

  return {
    count,
    activeReservations,
    expiredReservationIds,
    usedSlots: count + Object.keys(activeReservations).length,
  };
}

function buildIntegrationReservation(
  gcsUri: string,
  nowMs: number
): {
  gcsUriHash: string;
  createdAt: Timestamp;
  expiresAt: Timestamp;
} {
  return {
    gcsUriHash: createHash('sha256').update(gcsUri).digest('hex'),
    createdAt: Timestamp.fromMillis(nowMs),
    expiresAt: Timestamp.fromMillis(nowMs + RESERVATION_TTL_MS),
  };
}

function reservationDeleteUpdate(ids: string[]): Record<string, FieldValue> {
  const update: Record<string, FieldValue> = {};

  for (const id of ids) {
    update[`reservations.${id}`] = FieldValue.delete();
  }

  return update;
}

function isLimitExceededError(err: unknown): boolean {
  return err instanceof Error && err.message === LIMIT_EXCEEDED;
}

async function reserveUsageForIntegrationProbe(
  firestore: Firestore,
  userId: string,
  analysisRequestId: string,
  gcsUri: string,
  quotaWindow: UTCQuotaWindow
): Promise<void> {
  // Keep this probe on @google-cloud/firestore because GitHub Actions WIF
  // credentials are accepted here, but not by Firebase Admin ADC loading.
  const ref = firestore.collection('usage').doc(userId);
  const nowMs = Date.now();
  const reservation = buildIntegrationReservation(gcsUri, nowMs);

  await firestore.runTransaction(async (tx) => {
    const snap = await tx.get(ref);

    if (!snap.exists) {
      tx.set(ref, {
        count: 0,
        lastResetDate: quotaWindow.usageDate,
        reservations: {
          [analysisRequestId]: reservation,
        },
      });
      return;
    }

    const summary = summarizeIntegrationUsageQuota(
      snap.data() || {},
      quotaWindow.usageDate,
      nowMs
    );

    if (Object.prototype.hasOwnProperty.call(
      summary.activeReservations,
      analysisRequestId
    )) {
      throw new Error(RESERVATION_ALREADY_EXISTS);
    }

    if (summary.usedSlots >= DAILY_LIMIT) {
      throw new Error(LIMIT_EXCEEDED);
    }

    tx.update(ref, {
      ...reservationDeleteUpdate(summary.expiredReservationIds),
      count: summary.count,
      lastResetDate: quotaWindow.usageDate,
      [`reservations.${analysisRequestId}`]: reservation,
    });
  });
}

function activeReservationCount(value: unknown): number {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return 0;
  }

  return Object.keys(value).length;
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
      analysisRequestId: 'a6f97f91-330d-4bd8-a184-86eb520cf691',
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

async function verifyAtomicReservationRace(
  firestore: Firestore,
  testUserId: string,
  quotaWindow: UTCQuotaWindow
): Promise<void> {
  const doc = firestore.collection('usage').doc(testUserId);
  await doc.set({
    count: 4,
    lastResetDate: quotaWindow.usageDate,
  });

  const results = await Promise.allSettled([
    reserveUsageForIntegrationProbe(
      firestore,
      testUserId,
      '10000000-0000-4000-8000-000000000001',
      `gs://catvox-raw-videos-${projectId}/reservation-race-a.mov`,
      quotaWindow
    ),
    reserveUsageForIntegrationProbe(
      firestore,
      testUserId,
      '10000000-0000-4000-8000-000000000002',
      `gs://catvox-raw-videos-${projectId}/reservation-race-b.mov`,
      quotaWindow
    ),
  ]);

  const fulfilled = results.filter((result) => result.status === 'fulfilled');
  const rejected = results.filter((result) => result.status === 'rejected');

  assert(
    fulfilled.length === 1,
    `Expected exactly one reservation to commit, got ${fulfilled.length}`
  );
  assert(
    rejected.length === 1,
    `Expected exactly one reservation to be rejected, got ${rejected.length}`
  );

  const rejection = rejected[0];
  assert(
    rejection.status === 'rejected' && isLimitExceededError(rejection.reason),
    'Expected rejected reservation to fail with LIMIT_EXCEEDED'
  );

  const snap = await doc.get();
  const data = snap.data();
  const reservationCount = activeReservationCount(data?.reservations);

  assert(data?.count === 4, `Expected count to remain 4, got ${String(data?.count)}`);
  assert(
    reservationCount === 1,
    `Expected one active reservation after race, got ${reservationCount}`
  );

  console.log('Atomic quota reservation race verified');
}

async function main(): Promise<void> {
  try {
    assertMutationGateAllowed({
      confirmed,
      mutationsAllowed,
      environmentName,
      integrationSafeEnvironments,
    });
  } catch (error) {
    usage();
    throw error;
  }

  const testUserId = `quota-contract-test-${Date.now()}`;
  const reservationRaceUserId = `reservation-race-test-${Date.now()}`;
  const startTime = new Date(Date.now() - 1000);
  const quotaWindow = currentUTCQuotaWindow();
  const firestore = new Firestore({ projectId });
  const doc = firestore.collection('usage').doc(testUserId);
  const reservationRaceDoc = firestore.collection('usage').doc(reservationRaceUserId);

  console.log('Environment:', environmentName);
  console.log('Project:', projectId);
  console.log('Signed URL endpoint:', signedUrlEndpoint);
  console.log('Analyse endpoint:', analyseEndpoint);
  console.log('Temporary userId:', testUserId);
  console.log('Temporary reservation race userId:', reservationRaceUserId);
  console.log('App Check debug token:', describeDebugToken());

  try {
    const appCheckToken = await exchangeDebugTokenForAppCheckToken();
    console.log('App Check debug token exchanged');

    await verifyAppCheckUnauthorizedPreflight(testUserId);

    await verifyAtomicReservationRace(
      firestore,
      reservationRaceUserId,
      quotaWindow
    );

    await doc.set({
      count: 5,
      lastResetDate: quotaWindow.usageDate,
    });
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
    await Promise.all([
      doc.delete().catch((err: unknown) => {
        console.error('Failed to delete temporary quota doc:', err);
      }),
      reservationRaceDoc.delete().catch((err: unknown) => {
        console.error('Failed to delete temporary reservation race doc:', err);
      }),
    ]);
    console.log('Temporary Firestore docs deleted');
    await firestore.terminate();
  }
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
