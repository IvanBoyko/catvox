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

    func testEveryEventCapturePayloadIncludesConfiguredEnvironmentName() {
        let configuration = CatVoxAppConfiguration(environmentName: "qa")

        for event in AnalyticsService.Event.allCases {
            let payload = AnalyticsService.capturePayload(
                for: event,
                properties: ["source": "photos"],
                appConfiguration: configuration
            )

            XCTAssertEqual(payload.eventName, event.rawValue)
            XCTAssertEqual(payload.properties["source"] as? String, "photos")
            XCTAssertEqual(
                payload.properties["app_environment"] as? String,
                "qa",
                "\(event.rawValue) did not include app_environment"
            )
        }
    }

    func testIssue37RequiredEventsRemainRegistered() {
        let eventNames = Set(AnalyticsService.Event.allCases.map(\.rawValue))
        let requiredEventNames: Set<String> = [
            "scan_source_chosen",
            "photos_picker_opened",
            "photos_picker_cancelled",
            "photos_clip_selected",
            "video_validation_passed",
            "video_validation_failed",
            "recording_started",
            "recording_finished",
            "recording_retake_tapped",
            "recording_cancelled",
            "recording_completed",
            "analysis_completed",
            "analysis_failed",
            "analysis_retry_tapped",
            "quota_exceeded",
            "quota_card_shown",
            "share_export_started",
            "share_export_render_failed",
            "share_sheet_opened",
            "scan_shared",
            "share_sheet_cancelled",
            "scan_saved_to_photos",
            "photos_permission_denied",
            "share_save_failed",
            "scan_deleted",
            "upgrade_to_pro_tapped",
        ]

        XCTAssertTrue(requiredEventNames.isSubset(of: eventNames))
        XCTAssertEqual(AnalyticsService.Event.shareSheetOpened.rawValue, "share_sheet_opened")
        XCTAssertEqual(AnalyticsService.Event.scanShared.rawValue, "scan_shared")
    }
}
