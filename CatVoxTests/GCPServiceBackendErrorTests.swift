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

    func testAppCheckUnauthorizedPayloadMapsToVerificationFailure() {
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

        XCTAssertEqual(error, .appVerificationFailed)
    }

    func testAppVerificationFailureHasCleanUserFacingMessage() {
        XCTAssertEqual(
            GCPError.appVerificationFailed.localizedDescription,
            "App verification failed. For Debug builds, reinstall via Xcode or run make ios-device-launch with a fresh registered debug token."
        )
    }

    func testAppCheckTokenExchange403MapsToVerificationFailure() {
        let error = NSError(
            domain: "com.firebase.appCheck",
            code: 0,
            userInfo: [
                NSLocalizedFailureReasonErrorKey: """
                The server responded with an error:
                - URL: https://firebaseappcheck.googleapis.com/v1/projects/test/apps/test:exchangeDebugToken
                - HTTP status code: 403
                - Response body: {"error":{"status":"PERMISSION_DENIED"}}
                """,
            ]
        )

        XCTAssertEqual(GCPError.fromAppCheckTokenFetchError(error), .appVerificationFailed)
    }

    func testAppCheckServerUnreachableDoesNotMapToVerificationFailure() {
        let error = NSError(
            domain: "com.firebase.appCheck",
            code: 1,
            userInfo: [NSLocalizedFailureReasonErrorKey: "API request error."]
        )

        XCTAssertNil(GCPError.fromAppCheckTokenFetchError(error))
    }

    func testUrlErrorDoesNotMapToVerificationFailure() {
        XCTAssertNil(GCPError.fromAppCheckTokenFetchError(URLError(.notConnectedToInternet)))
    }

    func testGenericAppCheckErrorDoesNotMapToVerificationFailure() {
        let error = NSError(
            domain: "com.firebase.appCheck",
            code: 0,
            userInfo: [NSLocalizedFailureReasonErrorKey: "Cached token not found."]
        )

        XCTAssertNil(GCPError.fromAppCheckTokenFetchError(error))
    }
}
