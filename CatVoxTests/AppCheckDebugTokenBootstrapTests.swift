import XCTest
@testable import CatVox

#if DEBUG
final class AppCheckDebugTokenBootstrapTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private let preferredToken = "11111111-1111-1111-1111-111111111111"
    private let firebaseToken = "22222222-2222-2222-2222-222222222222"
    private let persistedToken = "33333333-3333-3333-3333-333333333333"

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
                AppCheckDebugTokenBootstrap.preferredEnvironmentVariable: " \(preferredToken) ",
                AppCheckDebugTokenBootstrap.firebaseEnvironmentVariable: firebaseToken,
            ],
            userDefaults: userDefaults,
            setEnvironment: { key, value in environmentWrites.append((key, value)) }
        )

        XCTAssertEqual(
            userDefaults.string(forKey: AppCheckDebugTokenBootstrap.userDefaultsKey),
            preferredToken
        )
        XCTAssertTrue(environmentWrites.isEmpty)
    }

    func testConfigurePersistsFirebaseEnvironmentTokenWhenPreferredIsAbsent() {
        var environmentWrites: [(String, String)] = []

        AppCheckDebugTokenBootstrap.configure(
            environment: [
                AppCheckDebugTokenBootstrap.firebaseEnvironmentVariable: " \(firebaseToken)\n",
            ],
            userDefaults: userDefaults,
            setEnvironment: { key, value in environmentWrites.append((key, value)) }
        )

        XCTAssertEqual(
            userDefaults.string(forKey: AppCheckDebugTokenBootstrap.userDefaultsKey),
            firebaseToken
        )
        XCTAssertTrue(environmentWrites.isEmpty)
    }

    func testConfigureRestoresPersistedTokenToPreferredEnvironmentVariable() {
        userDefaults.set(persistedToken, forKey: AppCheckDebugTokenBootstrap.userDefaultsKey)
        var environmentWrites: [(String, String)] = []

        AppCheckDebugTokenBootstrap.configure(
            environment: [:],
            userDefaults: userDefaults,
            setEnvironment: { key, value in environmentWrites.append((key, value)) }
        )

        XCTAssertEqual(environmentWrites.count, 1)
        XCTAssertEqual(environmentWrites.first?.0, AppCheckDebugTokenBootstrap.preferredEnvironmentVariable)
        XCTAssertEqual(environmentWrites.first?.1, persistedToken)
    }

    func testBlanksAndPlaceholdersAreIgnored() {
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("   "))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("abc"))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("11111111\n22222222"))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("YOUR-APP-CHECK-DEBUG-TOKEN"))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("$(APP_CHECK_DEBUG_TOKEN)"))
        XCTAssertNil(AppCheckDebugTokenBootstrap.normalizedDebugToken("<debug-token>"))

        userDefaults.set("YOUR-APP-CHECK-DEBUG-TOKEN", forKey: AppCheckDebugTokenBootstrap.userDefaultsKey)
        XCTAssertNil(AppCheckDebugTokenBootstrap.storedDebugToken(in: userDefaults))
    }

    func testClearStoredTokenRemovesPersistedDebugToken() {
        userDefaults.set(persistedToken, forKey: AppCheckDebugTokenBootstrap.userDefaultsKey)

        AppCheckDebugTokenBootstrap.clearStoredToken(in: userDefaults)

        XCTAssertNil(userDefaults.string(forKey: AppCheckDebugTokenBootstrap.userDefaultsKey))
    }
}
#endif
