# ADR-0016: Persist App Check Debug Token for Local iPhone Builds

- Status: Accepted
- Date: 2026-05-12
- Owners: Kathelix / CatVox
- Related docs: `docs/TRD.md`, `docs/DEBUG.md`, `CatVox/App/AppCheckDebugTokenBootstrap.swift`, `scripts/run-on-iphone.sh`

## Context

CatVox Debug builds use Firebase App Check's Debug Provider so local simulator
and physical-device development can call the App Check-protected backend. Release
builds use App Attest only.

On a physical iPhone, a Debug build can be launched once from Xcode or
`devicectl` with `FIRAAppCheckDebugToken` in the process environment, then later
be relaunched from the app icon with no launch environment. Firebase App Check
tokens have a short TTL, so a later refresh can fall back to a locally generated
debug token that is not registered in Firebase. That produces a 403 from
`exchangeDebugToken` before CatVox reaches its signed-upload or analysis
Functions.

Deleting and reinstalling the app can appear to fix the issue by clearing local
Firebase/App Check state, but it does not make future icon launches reliable.

## Decision

CatVox will persist the registered App Check debug token in the local app
container for Debug builds only:

- If `AppCheckDebugToken` or `FIRAAppCheckDebugToken` is present at Debug launch,
  CatVox stores the token in `UserDefaults`.
- If a later Debug launch has no token environment, CatVox restores the stored
  token into `AppCheckDebugToken` before creating `AppCheckDebugProviderFactory`.
- Release builds compile this bootstrap out and continue to use App Attest only.
- `make ios-device-launch` passes the registered debug token to `devicectl`
  launches without printing it, sourcing the token from the environment or local
  `terraform/terraform.tfvars`.

## Consequences

### Positive

- Physical-device Debug builds keep working after the App Check token TTL expires
  and the app is relaunched from the icon.
- No debug token is committed, logged, embedded in Release, or sent to CatVox
  backend endpoints outside Firebase App Check token exchange.
- The local development workflow becomes consistent with backend integration
  tests, which already use the registered Debug Provider token.

### Negative / Trade-offs

- A registered debug token can persist in the local Debug app container until the
  app is deleted or the token is revoked in Firebase.
- Developers must still treat debug tokens as secrets and rotate/revoke them if
  compromised.
- This does not change production attestation behavior or add a DeviceCheck
  fallback.
