const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildCompleteReservationUpdate,
  buildDailyQuotaExceededResponse,
  buildReleaseReservationUpdate,
  buildReservation,
  sendDailyQuotaExceededResponse,
  summarizeUsageQuota,
} = require('../lib/usageGuard.js');

function timestampLike(millis) {
  return { toMillis: () => millis };
}

test('buildDailyQuotaExceededResponse returns machine-readable daily quota payload', () => {
  const now = new Date('2026-05-01T09:15:16.973Z');

  const response = buildDailyQuotaExceededResponse(now);

  assert.deepEqual(response.body, {
    code: 'daily_scan_quota_exceeded',
    message: 'Daily scan limit reached. Come back tomorrow.',
    limit: 5,
    remaining: 0,
    resetAt: '2026-05-02T00:00:00Z',
  });
});

test('buildDailyQuotaExceededResponse retryAfter matches next UTC reset', () => {
  const now = new Date('2026-05-01T23:59:59.250Z');

  const response = buildDailyQuotaExceededResponse(now);

  assert.equal(response.body.resetAt, '2026-05-02T00:00:00Z');
  assert.equal(response.retryAfterSeconds, 1);
});

test('sendDailyQuotaExceededResponse writes status, headers, and shared body', () => {
  const calls = {
    headers: {},
    statusCode: null,
    body: null,
  };
  const res = {
    setHeader(name, value) {
      calls.headers[name] = value;
      return this;
    },
    status(code) {
      calls.statusCode = code;
      return {
        json(body) {
          calls.body = body;
        },
      };
    },
  };

  sendDailyQuotaExceededResponse(res, 'getSignedUploadURL');

  assert.equal(calls.statusCode, 429);
  assert.equal(calls.headers['Content-Type'], 'application/json');
  assert.match(calls.headers['Retry-After'], /^[1-9]\d*$/);
  assert.equal(calls.body.code, 'daily_scan_quota_exceeded');
  assert.equal(calls.body.limit, 5);
  assert.equal(calls.body.remaining, 0);
});

test('summarizeUsageQuota counts active reservations against the daily limit', () => {
  const now = Date.parse('2026-05-01T12:00:00Z');
  const summary = summarizeUsageQuota(
    {
      count: 4,
      lastResetDate: '2026-05-01',
      reservations: {
        'active-request': {
          gcsUriHash: 'hash',
          createdAt: timestampLike(now - 1000),
          expiresAt: timestampLike(now + 1000),
        },
      },
    },
    '2026-05-01',
    now
  );

  assert.equal(summary.count, 4);
  assert.equal(summary.usedSlots, 5);
  assert.deepEqual(Object.keys(summary.activeReservations), ['active-request']);
  assert.deepEqual(summary.expiredReservationIds, []);
});

test('summarizeUsageQuota ignores and reports expired reservations', () => {
  const now = Date.parse('2026-05-01T12:00:00Z');
  const summary = summarizeUsageQuota(
    {
      count: 4,
      lastResetDate: '2026-05-01',
      reservations: {
        'expired-request': {
          gcsUriHash: 'hash',
          createdAt: timestampLike(now - 10_000),
          expiresAt: timestampLike(now - 1000),
        },
      },
    },
    '2026-05-01',
    now
  );

  assert.equal(summary.usedSlots, 4);
  assert.deepEqual(Object.keys(summary.activeReservations), []);
  assert.deepEqual(summary.expiredReservationIds, ['expired-request']);
});

test('summarizeUsageQuota resets count for a new UTC quota day', () => {
  const now = Date.parse('2026-05-02T00:01:00Z');
  const summary = summarizeUsageQuota(
    {
      count: 5,
      lastResetDate: '2026-05-01',
    },
    '2026-05-02',
    now
  );

  assert.equal(summary.count, 0);
  assert.equal(summary.usedSlots, 0);
});

test('buildReservation hashes the GCS URI and expires after five minutes', () => {
  const now = Date.parse('2026-05-01T12:00:00Z');
  const reservation = buildReservation('gs://bucket/cat.mov', now);

  assert.equal(
    reservation.gcsUriHash,
    'd52056745f488888fb0d125ec58e72d8a88f40da40d7d2e9060860c244a3d2df'
  );
  assert.equal(reservation.createdAt.toMillis(), now);
  assert.equal(reservation.expiresAt.toMillis(), now + 5 * 60 * 1000);
});

test('buildCompleteReservationUpdate removes reservation and increments count', () => {
  const now = Date.parse('2026-05-01T12:00:00Z');
  const update = buildCompleteReservationUpdate(
    {
      count: 3,
      lastResetDate: '2026-05-01',
      reservations: {
        'analysis-request': {
          gcsUriHash: 'hash',
          createdAt: timestampLike(now - 1000),
          expiresAt: timestampLike(now + 1000),
        },
      },
    },
    '2026-05-01',
    now,
    'analysis-request'
  );

  assert.equal(update.count, 4);
  assert.equal(update.lastResetDate, '2026-05-01');
  assert.ok(Object.prototype.hasOwnProperty.call(update, 'reservations.analysis-request'));
});

test('buildReleaseReservationUpdate removes reservation without incrementing count', () => {
  const now = Date.parse('2026-05-01T12:00:00Z');
  const update = buildReleaseReservationUpdate(
    {
      count: 3,
      lastResetDate: '2026-05-01',
      reservations: {
        'analysis-request': {
          gcsUriHash: 'hash',
          createdAt: timestampLike(now - 1000),
          expiresAt: timestampLike(now + 1000),
        },
      },
    },
    '2026-05-01',
    now,
    'analysis-request'
  );

  assert.equal(update.count, undefined);
  assert.ok(Object.prototype.hasOwnProperty.call(update, 'reservations.analysis-request'));
});
