# ADR-0015: Reserve Quota Before Vertex Analysis

- Status: Accepted
- Date: 2026-05-07
- Owners: Kathelix / CatVox
- Related docs: `docs/TRD.md`, `functions/src/usageGuard.ts`, `functions/src/analyse.ts`

## Context

CatVox enforces a free-tier daily scan limit to control Vertex AI cost. Before
this decision, `analyseVideo` performed a non-mutating Firestore quota read near
the start of the request, invoked Gemini only after uploaded-object validation,
and incremented usage after a valid analysis payload was returned.

That preserved the product rule that failed analysis attempts do not burn quota,
but it left a race near the daily limit: two concurrent requests could both read
the same remaining slot before either one incremented usage, then both proceed
to Vertex AI.

Firestore transactions are the right primitive for protecting the quota state,
but external calls such as Gemini must not run inside a transaction because the
transaction function may be retried.

## Decision

`analyseVideo` will reserve one quota slot in Firestore after cheap request and
uploaded-object validation succeeds, but before invoking Vertex AI. The
reservation and quota availability check happen in one Firestore transaction.

The existing `usage/{userId}` document remains the quota owner. It stores:

```ts
{
  count: number,
  lastResetDate: "YYYY-MM-DD",
  reservations: {
    [analysisRequestId: string]: {
      gcsUriHash: string,
      createdAt: Timestamp,
      expiresAt: Timestamp
    }
  }
}
```

The quota invariant is:

```text
count + nonExpiredReservations <= DAILY_LIMIT
```

After Gemini returns a valid parsed payload, the backend completes the
reservation in a second Firestore transaction by deleting the reservation and
incrementing `count`. If analysis fails before a valid payload exists, the
backend best-effort releases the reservation. If cleanup cannot run, the
reservation expires after a short TTL and is pruned opportunistically by later
quota checks.

The iOS client must send a unique `analysisRequestId` with every `analyseVideo`
request. Requests missing this value or sending a malformed UUID are rejected
with HTTP 400. No compatibility path is required for older clients because the
app has not launched publicly.

```mermaid
sequenceDiagram
    autonumber
    participant A as analyseVideo request A
    participant B as analyseVideo request B
    participant T as Firestore transaction<br/>usage/{userId}
    participant G as Gemini / Vertex AI

    par Concurrent requests near quota limit
        A->>T: reserveUsage(userId, requestId=A)
        B->>T: reserveUsage(userId, requestId=B)
    end

    rect rgb(235, 245, 255)
        Note over T: Atomic reservation transaction
        T->>T: Read count + reservations
        T->>T: Remove expired reservations
        T->>T: usedSlots = count + activeReservations
        alt usedSlots < DAILY_LIMIT
            T->>T: Write reservations[A]
            T-->>A: Reservation committed
        else usedSlots >= DAILY_LIMIT
            T-->>B: Reject with quota exceeded
        end
    end

    A->>G: Call Gemini only after reservation commits
    G-->>A: Valid analysis payload

    rect rgb(235, 255, 240)
        Note over A,T: Atomic completion transaction
        A->>T: completeUsageReservation(A)
        T->>T: Remove reservations[A]
        T->>T: Increment count by 1
        T-->>A: Quota burn committed
    end

    A-->>Client: 200 analysis result
    B-->>Client: 429 daily_scan_quota_exceeded
```

## Consequences

### Positive

- Prevents concurrent near-limit requests from both proceeding to Gemini on the
  same remaining slot.
- Preserves the product rule that quota is consumed only for successful analysis
  payloads.
- Keeps quota ownership inside the existing `usage/{userId}` document.
- Gives abandoned in-flight work a bounded impact through reservation expiry.

### Negative / Trade-offs

- Adds a second write path around successful analysis: reserve before Gemini,
  then complete after Gemini.
- A backend crash after reservation and before completion can temporarily hold a
  slot until the reservation expires.
- This does not implement full `analyseVideo` idempotency or cached result
  replay; duplicate client retries can still cause duplicate Vertex calls if
  they use distinct request IDs.

## Implementation Notes

- Reservation TTL: 5 minutes.
- The server hashes the GCS URI before storing it in the reservation map.
- Signed URL issuance still performs only an availability check, but that check
  counts active analysis reservations.
- Full analysis idempotency remains a separate future enhancement.
