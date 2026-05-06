import XCTest
@testable import CatVox

final class GCPServiceBackendErrorTests: XCTestCase {
    func testDailyScanQuotaExceededPayloadMapsToQuotaError() {
        let payload = """
        {
          "code": "daily_scan_quota_exceeded",
          "message": "Daily scan limit reached. Come back tomorrow.",
          "limit": 5,
          "remaining": 0,
          "resetAt": "2026-05-02T00:00:00Z"
        }
        """

        let error = GCPError.fromBackendResponse(
            statusCode: 429,
            data: Data(payload.utf8)
        )

        XCTAssertEqual(error, .quotaExceeded)
    }

    func testUnknown429CodeDoesNotMapToQuotaError() {
        let payload = """
        {
          "code": "signed_upload_rate_limited",
          "message": "Try again shortly."
        }
        """

        let error = GCPError.fromBackendResponse(
            statusCode: 429,
            data: Data(payload.utf8)
        )

        XCTAssertNil(error)
    }

    func testMalformed429BodyDoesNotMapToQuotaError() {
        let error = GCPError.fromBackendResponse(
            statusCode: 429,
            data: Data("not json".utf8)
        )

        XCTAssertNil(error)
    }

    func testAppCheckUnauthorizedDoesNotMapToQuotaError() {
        let payload = """
        {
          "code": "app_check_unauthorized",
          "message": "App Check token is missing or invalid."
        }
        """

        let error = GCPError.fromBackendResponse(
            statusCode: 401,
            data: Data(payload.utf8)
        )

        XCTAssertNil(error)
    }
}
