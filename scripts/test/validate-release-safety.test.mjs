// Focused coverage for scripts/validate-release-safety.mjs — the protected-tier
// release-safety validator (issue #38, Step 5). Run with `make scripts-test` or
// `node --test scripts/test/validate-release-safety.test.mjs`.
//
// Each test builds a hermetic temp "repo root" holding a protected config, a
// mutable sibling, project.yml, the three gated Swift files, and the App Attest
// entitlement, then perturbs exactly one thing.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { validateReleaseSafety, parseProjectYaml } from '../validate-release-safety.mjs';

const PROTECTED_BASE = {
  CATVOX_PROJECT_ID: 'kathelix-catvox-shielded',
  CATVOX_ENVIRONMENT: 'shielded',
  CATVOX_ENVIRONMENT_PROTECTED: 'true',
  CATVOX_FUNCTION_REGION: 'us-central1',
  CATVOX_FIRESTORE_LOCATION: 'nam5',
  CATVOX_TF_STATE_BUCKET: 'catvox-tf-state-kathelix-catvox-shielded',
  CATVOX_GCP_CI_SERVICE_ACCOUNT: 'catvox-ci-sa@kathelix-catvox-shielded.iam.gserviceaccount.com',
  CATVOX_GCP_WIF_PROVIDER:
    'projects/953500951129/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider',
  CATVOX_GCP_WIF_GITHUB_REF: 'refs/heads/main',
  CATVOX_IOS_BUNDLE_ID: 'com.kathelix.catvox',
  CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'CatVox Shielded iOS',
  CATVOX_FIREBASE_IOS_APP_DELETION_POLICY: 'ABANDON',
  CATVOX_FIREBASE_APPLE_TEAM_ID: 'QYT76L5836',
  CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT: 'ENFORCED',
  CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM: 'true',
  CATVOX_SIGNED_UPLOAD_URL_HOST: 'signed.shielded.run.app',
  CATVOX_ANALYSE_VIDEO_HOST: 'analyse.shielded.run.app',
  CATVOX_FIREBASE_APP_ID: '1:953500951129:ios:shielded',
  CATVOX_FIREBASE_API_KEY: 'AIzaShieldedKey0000000000000000000000',
  CATVOX_POSTHOG_PROJECT_TOKEN: 'phc_shielded',
  CATVOX_POSTHOG_HOST_NAME: 'us.i.posthog.com',
  CATVOX_POSTHOG_API_HOST_NAME: 'us.posthog.com',
  CATVOX_POSTHOG_PROJECT_ID: '448206',
  CATVOX_POSTHOG_ORGANIZATION_ID: 'org-shielded',
  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS: '',
};

const MUTABLE_BASE = {
  CATVOX_PROJECT_ID: 'kathelix-catvox-mutable',
  CATVOX_ENVIRONMENT: 'mutable',
  CATVOX_ENVIRONMENT_PROTECTED: 'false',
  CATVOX_FUNCTION_REGION: 'us-central1',
  CATVOX_FIRESTORE_LOCATION: 'nam5',
  CATVOX_TF_STATE_BUCKET: 'catvox-tf-state-kathelix-catvox-mutable',
  CATVOX_GCP_CI_SERVICE_ACCOUNT: 'catvox-ci-sa@kathelix-catvox-mutable.iam.gserviceaccount.com',
  CATVOX_GCP_WIF_PROVIDER:
    'projects/99523926611/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider',
  CATVOX_GCP_WIF_GITHUB_REF: '',
  CATVOX_IOS_BUNDLE_ID: 'com.kathelix.catvox.mutable',
  CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'CatVox Mutable iOS',
  CATVOX_FIREBASE_IOS_APP_DELETION_POLICY: 'DELETE',
  CATVOX_FIREBASE_APPLE_TEAM_ID: 'QYT76L5836',
  CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT: 'UNENFORCED',
  CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM: 'true',
  CATVOX_SIGNED_UPLOAD_URL_HOST: 'signed.mutable.run.app',
  CATVOX_ANALYSE_VIDEO_HOST: 'analyse.mutable.run.app',
  CATVOX_FIREBASE_APP_ID: '1:99523926611:ios:mutable',
  CATVOX_FIREBASE_API_KEY: 'AIzaMutableKey00000000000000000000000',
  CATVOX_POSTHOG_PROJECT_TOKEN: 'phc_mutable',
  CATVOX_POSTHOG_HOST_NAME: 'us.i.posthog.com',
  CATVOX_POSTHOG_API_HOST_NAME: 'us.posthog.com',
  CATVOX_POSTHOG_PROJECT_ID: '402530',
  CATVOX_POSTHOG_ORGANIZATION_ID: 'org-mutable',
  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS: 'mutable',
};

const CLEAN_APP_SWIFT = `import FirebaseAppCheck

enum FirebaseSetup {
    static func configureFirebase() {
        #if DEBUG
        AppCheckDebugTokenBootstrap.configure()
        let providerFactory = AppCheckDebugProviderFactory()
        #else
        let providerFactory = CatVoxAppCheckProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(providerFactory)
    }
}

private final class CatVoxAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
`;

const CLEAN_BOOTSTRAP_SWIFT = `import Foundation

#if DEBUG
enum AppCheckDebugTokenBootstrap {
    static func configure() {}
}
#endif
`;

const CLEAN_CONFIG_SWIFT = `import Foundation

struct CatVoxAppConfiguration {
    #if DEBUG
    private static let debugDefaultEnvironmentName = "sample"
    #endif

    private static var runtimeAllowsDebugDefaults: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
`;

const PRODUCTION_ENTITLEMENTS = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>com.apple.developer.devicecheck.appattest-environment</key>
\t<string>production</string>
</dict>
</plist>
`;

function projectYml({
  release = 'shielded',
  debug = 'mutable',
  archive = 'Release',
  entitlements = 'CatVox/CatVox.entitlements',
  releaseEntitlements = null,
} = {}) {
  const lines = [
    'targets:',
    '  CatVox:',
    '    configFiles:',
    `      Debug: config/environments/${debug}.xcconfig`,
    `      Release: config/environments/${release}.xcconfig`,
  ];
  if (entitlements || releaseEntitlements) {
    lines.push('    settings:');
    if (entitlements) {
      lines.push('      base:', `        CODE_SIGN_ENTITLEMENTS: ${entitlements}`);
    }
    if (releaseEntitlements) {
      lines.push(
        '      configs:',
        '        Release:',
        `          CODE_SIGN_ENTITLEMENTS: ${releaseEntitlements}`
      );
    }
  }
  lines.push(
    'schemes:',
    '  CatVox:',
    '    archive:',
    `      config: ${archive}`,
    '  CatVoxUITests:',
    '    archive:',
    `      config: ${archive}`
  );
  return lines.join('\n') + '\n';
}

function render(base, overrides) {
  return (
    Object.entries({ ...base, ...overrides })
      .map(([key, value]) => `${key} = ${value}`)
      .join('\n') + '\n'
  );
}

function makeRoot({
  protectedOverrides = {},
  mutableOverrides = {},
  appSwift = CLEAN_APP_SWIFT,
  bootstrapSwift = CLEAN_BOOTSTRAP_SWIFT,
  configSwift = CLEAN_CONFIG_SWIFT,
  entitlements = PRODUCTION_ENTITLEMENTS,
  project = projectYml(),
  extraFiles = {},
} = {}) {
  const root = mkdtempSync(join(tmpdir(), 'catvox-release-safety-'));
  mkdirSync(join(root, 'config/environments'), { recursive: true });
  mkdirSync(join(root, 'CatVox/App'), { recursive: true });
  writeFileSync(
    join(root, 'config/environments/shielded.xcconfig'),
    render(PROTECTED_BASE, protectedOverrides)
  );
  writeFileSync(
    join(root, 'config/environments/mutable.xcconfig'),
    render(MUTABLE_BASE, mutableOverrides)
  );
  writeFileSync(join(root, 'CatVox/App/CatVoxApp.swift'), appSwift);
  writeFileSync(join(root, 'CatVox/App/AppCheckDebugTokenBootstrap.swift'), bootstrapSwift);
  writeFileSync(join(root, 'CatVox/App/CatVoxAppConfiguration.swift'), configSwift);
  writeFileSync(join(root, 'CatVox/CatVox.entitlements'), entitlements);
  writeFileSync(join(root, 'project.yml'), project);
  for (const [relativePath, content] of Object.entries(extraFiles)) {
    const target = join(root, relativePath);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, content);
  }
  return root;
}

function run(options = {}) {
  const root = makeRoot(options);
  return validateReleaseSafety({
    configPath: join(root, 'config/environments/shielded.xcconfig'),
    environmentName: 'shielded',
    root,
  });
}

test('a clean protected config + tree validates', () => {
  const result = run();
  assert.equal(result.isProtected, true);
});

test('auto-resolution still reports the protected environment', () => {
  const result = run();
  assert.match(result.configPath, /shielded\.xcconfig$/);
});

test("a foreign project id in a Release value is rejected", () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'CatVox kathelix-catvox-mutable' } }),
    /another environment's project/
  );
});

test('a foreign bundle id in a Release value is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'com.kathelix.catvox.mutable' } }),
    /another environment's bundle id/
  );
});

test('a foreign Firebase app id in a Release value is rejected', () => {
  assert.throws(
    () =>
      run({
        protectedOverrides: { CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME: 'app 1:99523926611:ios:mutable' },
      }),
    /another environment's Firebase app id/
  );
});

test('a foreign Firebase API key in a Release value is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_FIREBASE_API_KEY: 'AIzaMutableKey00000000000000000000000' } }),
    /Firebase API key/
  );
});

test('a foreign endpoint host in a Release value is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_SIGNED_UPLOAD_URL_HOST: 'signed.mutable.run.app' } }),
    /another environment's endpoint host/
  );
});

test('a foreign PostHog project token in a Release value is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_POSTHOG_PROJECT_TOKEN: 'phc_mutable' } }),
    /PostHog project token/
  );
});

test('a foreign PostHog project id in a Release value is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_POSTHOG_PROJECT_ID: '402530' } }),
    /PostHog project id/
  );
});

test('an App Check debug-token key in the Release config is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { TF_VAR_APP_CHECK_DEBUG_TOKEN: 'a-debug-token-value' } }),
    /debug token/i
  );
});

test('a remaining placeholder in the Release config is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_FIREBASE_APP_ID: 'replace-with-app-id' } }),
    /must not be a placeholder/
  );
});

test('a non-protected config is rejected', () => {
  assert.throws(
    () => run({ protectedOverrides: { CATVOX_ENVIRONMENT_PROTECTED: 'false' } }),
    /protected/
  );
});

test('a non-production App Attest entitlement is rejected', () => {
  assert.throws(
    () => run({ entitlements: PRODUCTION_ENTITLEMENTS.replace('production', 'development') }),
    /appattest-environment|production/
  );
});

test('a project.yml without CODE_SIGN_ENTITLEMENTS is rejected', () => {
  assert.throws(() => run({ project: projectYml({ entitlements: '' }) }), /CODE_SIGN_ENTITLEMENTS/);
});

test('CODE_SIGN_ENTITLEMENTS repointed to a non-production file is rejected', () => {
  // CatVox/CatVox.entitlements still has production, but the build signs with a
  // different file — the check must follow CODE_SIGN_ENTITLEMENTS, not the name.
  assert.throws(
    () =>
      run({
        project: projectYml({ entitlements: 'CatVox/Other.entitlements' }),
        extraFiles: {
          'CatVox/Other.entitlements': PRODUCTION_ENTITLEMENTS.replace('production', 'development'),
        },
      }),
    /appattest-environment|production/
  );
});

test('CODE_SIGN_ENTITLEMENTS repointed to a missing file is rejected', () => {
  assert.throws(
    () => run({ project: projectYml({ entitlements: 'CatVox/Missing.entitlements' }) }),
    /Could not read entitlements/
  );
});

test('a Release config-specific CODE_SIGN_ENTITLEMENTS override is honored over base', () => {
  // base points at the production entitlements, but the Release config overrides
  // it to a development file — the effective Release entitlement must be checked.
  assert.throws(
    () =>
      run({
        project: projectYml({ releaseEntitlements: 'CatVox/Dev.entitlements' }),
        extraFiles: {
          'CatVox/Dev.entitlements': PRODUCTION_ENTITLEMENTS.replace('production', 'development'),
        },
      }),
    /appattest-environment|production/
  );
});

test('the debug App Check provider escaping #if DEBUG is rejected', () => {
  const ungated = `import FirebaseAppCheck

enum FirebaseSetup {
    static func configureFirebase() {
        #if DEBUG
        AppCheckDebugTokenBootstrap.configure()
        #else
        let providerFactory = AppCheckDebugProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(providerFactory)
    }
}

private final class CatVoxAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
`;
  assert.throws(() => run({ appSwift: ungated }), /AppCheckDebugProviderFactory/);
});

test('a Release branch that selects a non-App-Attest factory is rejected', () => {
  // The production factory name still appears (in the DEBUG branch), so a
  // whole-file string match would pass; the #else branch must be verified.
  const swapped = `import FirebaseAppCheck

enum FirebaseSetup {
    static func configureFirebase() {
        #if DEBUG
        AppCheckDebugTokenBootstrap.configure()
        let providerFactory = CatVoxAppCheckProviderFactory()
        #else
        let providerFactory = LegacyAppCheckProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(providerFactory)
    }
}

private final class CatVoxAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
`;
  assert.throws(() => run({ appSwift: swapped }), /production App Check provider factory/);
});

test('a production factory that drops AppAttestProvider is rejected', () => {
  const noAppAttest = `import FirebaseAppCheck

enum FirebaseSetup {
    static func configureFirebase() {
        #if DEBUG
        AppCheckDebugTokenBootstrap.configure()
        let providerFactory = AppCheckDebugProviderFactory()
        #else
        let providerFactory = CatVoxAppCheckProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(providerFactory)
    }
}

private final class CatVoxAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        DeviceCheckProvider(app: app)
    }
}
`;
  assert.throws(() => run({ appSwift: noAppAttest }), /AppAttestProvider/);
});

test('the debug-token bootstrap defined outside #if DEBUG is rejected', () => {
  const ungated = `import Foundation

enum AppCheckDebugTokenBootstrap {
    static func configure() {}
}
`;
  assert.throws(() => run({ bootstrapSwift: ungated }), /AppCheckDebugTokenBootstrap must be defined inside #if DEBUG/);
});

test('dev fallback endpoints outside #if DEBUG are rejected', () => {
  const ungated = `import Foundation

struct CatVoxAppConfiguration {
    private static let debugDefaultEnvironmentName = "sample"

    private static var runtimeAllowsDebugDefaults: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
`;
  assert.throws(() => run({ configSwift: ungated }), /debugDefault/);
});

test('runtimeAllowsDebugDefaults returning true in Release is rejected', () => {
  const releaseAllows = `import Foundation

struct CatVoxAppConfiguration {
    #if DEBUG
    private static let debugDefaultEnvironmentName = "sample"
    #endif

    private static var runtimeAllowsDebugDefaults: Bool {
        #if DEBUG
        return true
        #else
        return true
        #endif
    }
}
`;
  assert.throws(() => run({ configSwift: releaseAllows }), /runtimeAllowsDebugDefaults/);
});

test('binding the Release configuration to a mutable environment is rejected', () => {
  assert.throws(
    () => run({ project: projectYml({ release: 'mutable', debug: 'mutable' }) }),
    /must be a protected environment/
  );
});

test('a scheme that archives with Debug is rejected', () => {
  assert.throws(() => run({ project: projectYml({ archive: 'Debug' }) }), /Release configuration/);
});

test('a scheme that archives with a Release-prefixed custom config is rejected', () => {
  // `Release-dev` must not be accepted just because it starts with "Release".
  assert.throws(() => run({ project: projectYml({ archive: 'Release-dev' }) }), /Release configuration/);
});

test('parseProjectYaml navigates nested maps and a config-specific override', () => {
  const parsed = parseProjectYaml(projectYml({ releaseEntitlements: 'CatVox/Dev.entitlements' }));
  assert.equal(parsed.targets.CatVox.configFiles.Release, 'config/environments/shielded.xcconfig');
  assert.equal(parsed.targets.CatVox.settings.base.CODE_SIGN_ENTITLEMENTS, 'CatVox/CatVox.entitlements');
  assert.equal(
    parsed.targets.CatVox.settings.configs.Release.CODE_SIGN_ENTITLEMENTS,
    'CatVox/Dev.entitlements'
  );
  assert.equal(parsed.schemes.CatVox.archive.config, 'Release');
  assert.equal(parsed.schemes.CatVoxUITests.archive.config, 'Release');
});
