import XCTest
@testable import CatVox

@MainActor
final class GCPServiceRequestTests: XCTestCase {
    func testSignedURLRequestIncludesAppCheckHeaderAndBody() throws {
        let endpoint = URL(string: "https://example.com/getSignedUploadURL")!
        let videoURL = URL(fileURLWithPath: "/tmp/catvox-clip.mov")

        let request = try GCPService.makeSignedURLRequest(
            endpoint: endpoint,
            videoURL: videoURL,
            contentType: "video/quicktime",
            userId: "user-123",
            appCheckToken: "app-check-token"
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check-token")

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded["filename"], "catvox-clip.mov")
        XCTAssertEqual(decoded["contentType"], "video/quicktime")
        XCTAssertEqual(decoded["userId"], "user-123")
    }

    func testAnalysisRequestIncludesAppCheckHeaderAndBody() throws {
        let endpoint = URL(string: "https://example.com/analyseVideo")!

        let request = try GCPService.makeAnalysisRequest(
            endpoint: endpoint,
            gcsUri: "gs://catvox-raw-videos-test/cat.mov",
            userId: "user-123",
            analysisRequestID: UUID(uuidString: "A6F97F91-330D-4BD8-A184-86EB520CF691")!,
            appCheckToken: "app-check-token"
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check-token")

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded["gcsUri"], "gs://catvox-raw-videos-test/cat.mov")
        XCTAssertEqual(decoded["userId"], "user-123")
        XCTAssertEqual(decoded["analysisRequestId"], "A6F97F91-330D-4BD8-A184-86EB520CF691")
    }

    func testBackendSessionConfigurationUsesExplicitTimeouts() {
        let config = GCPService.makeBackendSessionConfiguration(timeout: 150)

        XCTAssertEqual(config.timeoutIntervalForRequest, 150)
        XCTAssertEqual(config.timeoutIntervalForResource, 150)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(config.urlCache)
        XCTAssertTrue(config.waitsForConnectivity)
    }

    func testPipelinePhaseFailureTitlesMatchCurrentStep() {
        XCTAssertEqual(GCPService.PipelinePhase.preparing.failureTitle, "Connection Failed")
        XCTAssertEqual(GCPService.PipelinePhase.uploading.failureTitle, "Upload Failed")
        XCTAssertEqual(GCPService.PipelinePhase.analysing.failureTitle, "Analysis Failed")
    }

    func testAppVerificationFailedUploadStateIsDistinct() {
        XCTAssertEqual(
            GCPService.UploadState.appVerificationFailed,
            GCPService.UploadState.appVerificationFailed
        )
        XCTAssertNotEqual(
            GCPService.UploadState.appVerificationFailed,
            GCPService.UploadState.failed(.preparing, GCPError.appVerificationFailed.localizedDescription)
        )
    }
}
