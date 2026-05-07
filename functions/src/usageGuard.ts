import * as logger from 'firebase-functions/logger';
import { createHash } from 'crypto';
import {
  getFirestore,
  FieldValue,
  Timestamp,
} from 'firebase-admin/firestore';

const DAILY_LIMIT = 5;
const RESERVATION_TTL_MS = 5 * 60 * 1000;
export const LIMIT_EXCEEDED = 'LIMIT_EXCEEDED';
export const RESERVATION_ALREADY_EXISTS = 'RESERVATION_ALREADY_EXISTS';
export const DAILY_SCAN_QUOTA_EXCEEDED_CODE = 'daily_scan_quota_exceeded';
const DAILY_SCAN_QUOTA_EXCEEDED_MESSAGE =
  'Daily scan limit reached. Come back tomorrow.';

export type QuotaEndpoint = 'getSignedUploadURL' | 'analyseVideo';

export type DailyQuotaExceededBody = {
  code: typeof DAILY_SCAN_QUOTA_EXCEEDED_CODE;
  message: string;
  limit: number;
  remaining: number;
  resetAt: string;
};

type DailyQuotaExceededResponse = {
  body: DailyQuotaExceededBody;
  retryAfterSeconds: number;
};

type QuotaResponseLike = {
  setHeader(name: string, value: string): unknown;
  status(code: number): {
    json(body: DailyQuotaExceededBody): unknown;
  };
};

type ReservationRecord = {
  gcsUriHash?: unknown;
  createdAt?: unknown;
  expiresAt?: unknown;
};

type ActiveReservations = Record<string, ReservationRecord>;

export type UsageQuotaSummary = {
  count: number;
  activeReservations: ActiveReservations;
  expiredReservationIds: string[];
  usedSlots: number;
};

function todayUTC(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD
}

/**
 * Availability check used at request gates where we want to reject
 * already-exhausted users without consuming a usage unit yet. It counts active
 * analysis reservations so signed URL issuance cannot get ahead of in-flight
 * quota claims, and it may prune expired reservations opportunistically.
 */
export async function checkUsageAvailable(userId: string): Promise<void> {
  const db = getFirestore();
  const ref = db.collection('usage').doc(userId);
  const today = todayUTC();
  const nowMs = Date.now();

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      return;
    }

    const summary = summarizeUsageQuota(snap.data()!, today, nowMs);

    if (summary.expiredReservationIds.length > 0) {
      tx.update(ref, reservationDeleteUpdate(summary.expiredReservationIds));
    }

    if (summary.usedSlots >= DAILY_LIMIT) {
      throw new Error(LIMIT_EXCEEDED);
    }
  });
}

/**
 * Atomically reserves one scan slot before Vertex AI work starts. The expensive
 * model call must happen only after this transaction commits.
 */
export async function reserveUsage(
  userId: string,
  analysisRequestId: string,
  gcsUri: string
): Promise<void> {
  const db = getFirestore();
  const ref = db.collection('usage').doc(userId);
  const today = todayUTC();
  const nowMs = Date.now();
  const reservation = buildReservation(gcsUri, nowMs);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);

    if (!snap.exists) {
      tx.set(ref, {
        count: 0,
        lastResetDate: today,
        reservations: {
          [analysisRequestId]: reservation,
        },
      });
      return;
    }

    const summary = summarizeUsageQuota(snap.data()!, today, nowMs);

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
      lastResetDate: today,
      [`reservations.${analysisRequestId}`]: reservation,
    });
  });
}

/**
 * Converts a successful reservation into a burned quota unit.
 */
export async function completeUsageReservation(
  userId: string,
  analysisRequestId: string
): Promise<void> {
  const db = getFirestore();
  const ref = db.collection('usage').doc(userId);
  const today = todayUTC();
  const nowMs = Date.now();

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);

    if (!snap.exists) {
      tx.set(ref, { count: 1, lastResetDate: today });
      return;
    }

    tx.update(ref, buildCompleteReservationUpdate(
      snap.data()!,
      today,
      nowMs,
      analysisRequestId
    ));
  });
}

/**
 * Releases an in-flight reservation when analysis fails before a valid payload
 * is produced. If this best-effort cleanup fails, the reservation expires.
 */
export async function releaseUsageReservation(
  userId: string,
  analysisRequestId: string
): Promise<void> {
  const db = getFirestore();
  const ref = db.collection('usage').doc(userId);
  const today = todayUTC();
  const nowMs = Date.now();

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      return;
    }

    tx.update(ref, buildReleaseReservationUpdate(
      snap.data()!,
      today,
      nowMs,
      analysisRequestId
    ));
  });
}

export function isLimitExceededError(err: unknown): boolean {
  return err instanceof Error && err.message === LIMIT_EXCEEDED;
}

export function isReservationAlreadyExistsError(err: unknown): boolean {
  return err instanceof Error && err.message === RESERVATION_ALREADY_EXISTS;
}

export function buildDailyQuotaExceededResponse(
  now = new Date()
): DailyQuotaExceededResponse {
  const resetAt = nextUTCDate(now);
  const retryAfterSeconds = Math.max(
    1,
    Math.ceil((resetAt.getTime() - now.getTime()) / 1000)
  );

  return {
    body: {
      code: DAILY_SCAN_QUOTA_EXCEEDED_CODE,
      message: DAILY_SCAN_QUOTA_EXCEEDED_MESSAGE,
      limit: DAILY_LIMIT,
      remaining: 0,
      resetAt: formatUTCInstant(resetAt),
    },
    retryAfterSeconds,
  };
}

export function sendDailyQuotaExceededResponse(
  res: QuotaResponseLike,
  endpoint: QuotaEndpoint
): void {
  const { body, retryAfterSeconds } = buildDailyQuotaExceededResponse();

  logger.info('quota_exceeded', {
    event: 'quota_exceeded',
    quotaType: 'daily_scan',
    endpoint,
    limit: body.limit,
    remaining: body.remaining,
    resetAt: body.resetAt,
  });

  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Retry-After', String(retryAfterSeconds));
  res.status(429).json(body);
}

function nextUTCDate(from: Date): Date {
  return new Date(Date.UTC(
    from.getUTCFullYear(),
    from.getUTCMonth(),
    from.getUTCDate() + 1,
    0,
    0,
    0,
    0
  ));
}

function formatUTCInstant(date: Date): string {
  return date.toISOString().replace('.000Z', 'Z');
}

export function summarizeUsageQuota(
  data: Record<string, unknown>,
  today: string,
  nowMs: number
): UsageQuotaSummary {
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

export function buildReservation(
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

export function buildCompleteReservationUpdate(
  data: Record<string, unknown>,
  today: string,
  nowMs: number,
  analysisRequestId: string
): Record<string, unknown> {
  const summary = summarizeUsageQuota(data, today, nowMs);

  return {
    ...reservationDeleteUpdate([
      ...summary.expiredReservationIds,
      analysisRequestId,
    ]),
    count: summary.count + 1,
    lastResetDate: today,
  };
}

export function buildReleaseReservationUpdate(
  data: Record<string, unknown>,
  today: string,
  nowMs: number,
  analysisRequestId: string
): Record<string, unknown> {
  const summary = summarizeUsageQuota(data, today, nowMs);

  return reservationDeleteUpdate([
    ...summary.expiredReservationIds,
    analysisRequestId,
  ]);
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

function reservationDeleteUpdate(ids: string[]): Record<string, FieldValue> {
  const update: Record<string, FieldValue> = {};

  for (const id of ids) {
    update[`reservations.${id}`] = FieldValue.delete();
  }

  return update;
}
