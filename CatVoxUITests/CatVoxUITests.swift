import XCTest

final class CatVoxUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testHomeScreenSmoke() {
        launchApp()

        XCTAssertTrue(element("home.readMyCatButton").waitForExistence(timeout: 8))
        XCTAssertTrue(element("home.historyList").waitForExistence(timeout: 4))
        XCTAssertTrue(element("home.quotaStatus").waitForExistence(timeout: 4))
    }

    func testSourceChoiceFlowCanBeDismissed() {
        launchApp()

        let readMyCatButton = element("home.readMyCatButton")
        XCTAssertTrue(readMyCatButton.waitForExistence(timeout: 8))
        readMyCatButton.tap()

        let recordNewVideoButton = element("source.recordNewVideoButton")
        let chooseFromPhotosButton = element("source.chooseFromPhotosButton")
        let cancelButton = element("source.cancelButton")

        XCTAssertTrue(recordNewVideoButton.waitForExistence(timeout: 4))
        XCTAssertTrue(chooseFromPhotosButton.waitForExistence(timeout: 1))
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 1))

        cancelButton.tap()
        XCTAssertTrue(recordNewVideoButton.waitForNonExistence(timeout: 4))
    }

    func testSeededHistoryReplayOpensResultWithoutUpload() {
        launchApp(arguments: ["-seedHistory"])

        let historyItem = element("home.historyItem.0")
        XCTAssertTrue(historyItem.waitForExistence(timeout: 8))
        historyItem.tap()

        XCTAssertTrue(element("result.screen").waitForExistence(timeout: 6))
        XCTAssertTrue(element("result.catThoughtText").waitForExistence(timeout: 8))
        XCTAssertFalse(element("upload.progressCard").exists)
    }

    func testMockedQuotaExceededStateRendersUpgradeUIWithoutUpload() {
        launchApp(arguments: ["-forceQuotaExceeded"])

        let readMyCatButton = element("home.readMyCatButton")
        XCTAssertTrue(readMyCatButton.waitForExistence(timeout: 8))
        readMyCatButton.tap()

        XCTAssertTrue(element("quota.card").waitForExistence(timeout: 4))
        XCTAssertTrue(element("quota.upgradeButton").waitForExistence(timeout: 1))
        XCTAssertFalse(element("source.recordNewVideoButton").exists)
        XCTAssertFalse(element("upload.progressCard").exists)
    }

    private func launchApp(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-mockBackend"] + arguments
        app.launchEnvironment["CATVOX_DISABLE_ANALYTICS"] = "1"
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
