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
    }
}
