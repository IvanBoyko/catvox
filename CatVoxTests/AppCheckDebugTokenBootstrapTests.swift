import XCTest
@testable import CatVox

#if DEBUG
final class AppCheckDebugTokenBootstrapTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.kathelix.catvox.tests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testConfigurePersistsPreferredEnvironmentToken() {
        var environmentWrites: [(String, String)] = []

        AppCheckDebugTokenBootstrap.configure(
            environment: [
                AppCheckDebugTokenBootstrap.preferredEnvironmentVariable: " preferred-token ",
                AppCheckDebugTokenBootstrap.firebaseEnvironmentVariable: "firebase-token",
            ],
            userDefaults: userDefaults,
            setEnvironment: { key, value in environmentWrites.append((key, value)) }
        )

        XCTAssertEqual(
            userDefaults.string(forKey: AppCheckDebugTokenBootstrap.userDefaultsKey),
            "preferred-token"
        )
        XCTAssertTrue(environmentWrites.isEmpty)
    }

    func testConfigurePersistsFirebaseEnvironmentTokenWhenPreferredIsAbsent() {
        AppCheckDebugTokenBootstrap.configure(
            environment: [
                AppCheckDebugTokenBootstrap.firebaseEnvironmentVariable: " firebase-token\n",
            ],
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            userDefaults.string(forKey: AppCheckDebugTokenBootstrap.userDefaultsKey),
            "firebase-token"
        )
    }

    func testConfigureRestoresPersistedTokenToPreferredEnvironmentVariable() {
        userDefaults.set("persisted-token", forKey: AppCheckDebugTokenBootstrap.userDefaultsKey)
        var environmentWrites: [(String, String)] = []

        AppCheckDebugTokenBootstrap.configure(
            environment: [:],
            userDefaults: userDefaults,
            setEnvironment: { key, value in environmentWrites.append((key, value)) }
        )

        XCTAssertEqual(environmentWrites.count, 1)
        XCTAssertEqual(environmentWrites.first?.0, AppCheckDebugTokenBootstrap.preferredEnvironmentVariable)
        XCTAssertEqual(environmentWrites.first?.1, "persisted-token")
    }

    func testBlanksAndPlaceholdersAreIgnored() {
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("   "))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("YOUR-APP-CHECK-DEBUG-TOKEN"))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("$(APP_CHECK_DEBUG_TOKEN)"))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("<debug-token>"))

        userDefaults.set("YOUR-APP-CHECK-DEBUG-TOKEN", forKey: AppCheckDebugTokenBootstrap.userDefaultsKey)
        XCTAssertNil(AppCheckDebugTokenBootstrap.storedDebugToken(in: userDefaults))
    }
}
#endif
