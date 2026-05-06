# iOS UI Testing

CatVox uses a small native XCUITest suite for user-visible iOS smoke coverage.
The suite is intentionally separate from backend integration tests: UI tests run
with mocked app/backend state, while integration tests validate live Dev backend
contracts.

## Local Command

Run UI tests from the repository root:

```bash
make ios-ui-test
```

The target regenerates the Xcode project from `project.yml` and runs the
`CatVoxUITests` scheme on a concrete simulator destination. Override the
simulator when needed:

```bash
IOS_UI_TEST_DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=latest" make ios-ui-test
```

## Launch Arguments

The UI test target launches the app with:

| Argument | Purpose |
|---|---|
| `-uiTesting` | Enables deterministic UI-test mode, disables analytics, resets test-local state, and uses in-memory SwiftData storage. |
| `-mockBackend` | Forces upload/analysis flows that are reached during UI testing to use the in-app mock pipeline instead of Firebase, GCS, or Gemini. |
| `-seedHistory` | Seeds one deterministic local history item for history-replay coverage. |
| `-forceQuotaExceeded` | Starts the app with zero scans remaining so the quota/upgrade UI can be tested without backend calls. |

## Current Coverage

The first suite covers:

* Home launch smoke: primary CTA, history area, and quota/status text.
* Source choice: source actions are visible and the chooser can be dismissed.
* Seeded history replay: a saved scan opens the Result screen without upload or analysis.
* Mocked quota exceeded: the upgrade card renders without entering a real backend flow.

The suite does not use real camera capture, Photos picker content, user
accounts, Firebase App Check, GCS upload, Gemini/Vertex AI, network calls, local
absolute paths, screenshots, snapshot testing, Appium, Maestro, BrowserStack, or
Firebase Test Lab.

## Extension Path

The app state is controlled through launch arguments and app-owned seed data, so
the same tests can later run on real devices in Firebase Test Lab or BrowserStack
with minimal changes. Future cloud execution should keep the native XCUITest
bundle and pass the same launch arguments through the provider-specific test
runner rather than introducing a second automation framework.
