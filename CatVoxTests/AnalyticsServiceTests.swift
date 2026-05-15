import XCTest
@testable import CatVox

final class AnalyticsServiceTests: XCTestCase {
    func testEventPropertiesIncludeConfiguredEnvironmentName() {
        let configuration = CatVoxAppConfiguration(environmentName: "staging")

        let properties = AnalyticsService.eventProperties(
            ["source": "photos"],
            appConfiguration: configuration
        )

        XCTAssertEqual(properties["source"] as? String, "photos")
        XCTAssertEqual(properties["app_environment"] as? String, "staging")
    }
}
