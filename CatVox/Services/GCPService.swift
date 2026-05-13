import Foundation
import FirebaseAppCheck
import Observation
import os

/// Transport layer for CatVox video uploads.
///
/// Pipeline:
///   1. Fetch a short-lived signed PUT URL from the Firebase Cloud Function.
///   2. Stream the local video file to Google Cloud Storage via HTTP PUT
///      with the content type inferred from the file container.
///   3. Trigger the Vertex AI analysis Cloud Function and return a CatAnalysis.
///
/// Mock mode:
///   Simulates the full pipeline with realistic delays so every UI state
///   transition can be exercised without a live server connection.
@MainActor
@Observable
final class GCPService {

    // MARK: - Upload state

    enum UploadState: Equatable {
        case idle
        case fetchingSignedURL
        case uploading(Double)        // 0.0 – 1.0 byte progress
        case analysing
        case complete(CatAnalysis)
        case quotaExceeded
        case failed(PipelinePhase, String)

        static func == (lhs: UploadState, rhs: UploadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle,              .idle),
                 (.fetchingSignedURL, .fetchingSignedURL),
                 (.analysing,         .analysing):
                return true
            case let (.uploading(a),  .uploading(b)):
                return a == b
            case let (.complete(a),   .complete(b)):
                return a.id == b.id
            case (.quotaExceeded,    .quotaExceeded):
                return true
            case let (.failed(aPhase, aMessage), .failed(bPhase, bMessage)):
                return aPhase == bPhase && aMessage == bMessage
            default:
                return false
            }
        }
    }

    enum PipelinePhase: Equatable {
        case preparing
        case uploading
        case analysing

        var failureTitle: String {
            switch self {
            case .preparing:
                return "Connection Failed"
            case .uploading:
                return "Upload Failed"
            case .analysing:
                return "Analysis Failed"
            }
        }
    }

    // MARK: - Configuration

    /// `true`  — simulated delays, mock CatAnalysis (no server required).
    /// `false` — real GCS upload + backend analysis.
    var mockMode: Bool = false
    var forceQuotaExceeded: Bool = false

    // MARK: - Observable properties

    private(set) var uploadState: UploadState = .idle

    // MARK: - Private

    private var currentTask: Task<Void, Never>?
    private var currentRequestID = UUID()

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.kathelix.catvox", category: "GCPService")

    // MARK: - Backend endpoints

    private enum Endpoint {
        static let signedURL = URL(
            string: "https://getsigneduploadurl-pdkw5uifga-uc.a.run.app")!
        static let analyse   = URL(
            string: "https://analysevideo-pdkw5uifga-uc.a.run.app")!
    }

    private enum Header {
        static let contentType = "Content-Type"
        static let appCheck = "X-Firebase-AppCheck"
    }

    private enum BackendTimeout {
        static let signedURL: TimeInterval = 45
        static let analysis: TimeInterval = 150
    }

    // MARK: - User identity

    /// Persistent anonymous device identifier used for per-user usage quota enforcement.
    /// Stored in UserDefaults on first launch. Replace with Firebase Auth UID once Auth is added.
    private var userId: String {
        UserIdentityStore.userID
    }

    // MARK: - Public API

    /// Starts the upload + analysis pipeline. Cancels any in-flight request first.
    func uploadAndAnalyse(videoAt localURL: URL) {
        currentTask?.cancel()
        let requestID = UUID()
        currentRequestID = requestID
        uploadState = .fetchingSignedURL
        currentTask = Task { await run(localURL: localURL, requestID: requestID) }
    }

    /// Re-starts the pipeline after a failure.
    func retry(videoAt localURL: URL) {
        uploadState = .idle
        uploadAndAnalyse(videoAt: localURL)
    }

    /// Cancels any in-flight task and returns to `.idle`.
    func reset() {
        currentTask?.cancel()
        currentRequestID = UUID()
        uploadState = .idle
    }

    // MARK: - Pipeline orchestration

    private func run(localURL: URL, requestID: UUID) async {
        do {
            if mockMode {
                try await mockPipeline(requestID: requestID)
            } else {
                try await realPipeline(localURL: localURL, requestID: requestID)
            }
        } catch GCPError.quotaExceeded {
            setUploadState(.quotaExceeded, for: requestID)
        } catch let failure as PipelinePhaseFailure {
            logger.error("pipeline failed during \(String(describing: failure.phase)): \(failure.underlying.localizedDescription)")
            setUploadState(.failed(failure.phase, failure.localizedDescription), for: requestID)
        } catch {
            if isCancellation(error) {
                setUploadState(.idle, for: requestID)
                return
            }

            logger.error("pipeline failed: \(error)")
            setUploadState(.failed(.preparing, error.localizedDescription), for: requestID)
        }
    }

    // MARK: - Mock pipeline

    private func mockPipeline(requestID: UUID) async throws {
        if forceQuotaExceeded {
            try await Task.sleep(for: .milliseconds(150))
            try Task.checkCancellation()
            setUploadState(.quotaExceeded, for: requestID)
            return
        }

        // Step 1 — simulate signed URL negotiation
        setUploadState(.fetchingSignedURL, for: requestID)
        try await Task.sleep(for: .seconds(0.7))
        try Task.checkCancellation()

        // Step 2 — simulate chunked upload with smooth progress
        let steps = 25
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(70))
            try Task.checkCancellation()
            setUploadState(.uploading(Double(step) / Double(steps)), for: requestID)
        }

        // Step 3 — simulate Vertex AI analysis latency
        setUploadState(.analysing, for: requestID)
        try await Task.sleep(for: .seconds(1.4))
        try Task.checkCancellation()

        setUploadState(.complete(MockAnalysisService.sampleAnalysis), for: requestID)
    }

    // MARK: - Real pipeline

    private func realPipeline(localURL: URL, requestID: UUID) async throws {
        let contentType = ImportedVideoService.mimeType(for: localURL)

        setUploadState(.fetchingSignedURL, for: requestID)
        let (signedURL, gcsUri) = try await runPipelinePhase(.preparing) {
            try await fetchSignedURL(
                for: localURL,
                contentType: contentType
            )
        }
        try Task.checkCancellation()

        setUploadState(.uploading(0), for: requestID)
        try await runPipelinePhase(.uploading) {
            try await upload(
                fileURL: localURL,
                to: signedURL,
                contentType: contentType,
                requestID: requestID
            )
        }
        try Task.checkCancellation()

        setUploadState(.analysing, for: requestID)
        let analysis = try await runPipelinePhase(.analysing) {
            try await triggerAnalysis(gcsUri: gcsUri, analysisRequestID: requestID)
        }
        setUploadState(.complete(analysis), for: requestID)
    }

    private func runPipelinePhase<T>(
        _ phase: PipelinePhase,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch GCPError.quotaExceeded {
            throw GCPError.quotaExceeded
        } catch {
            if isCancellation(error) {
                throw error
            }

            throw PipelinePhaseFailure(phase: phase, underlying: error)
        }
    }

    /// Returns `(signedURL, gcsUri)` — the signed PUT URL for the upload and
    /// the GCS URI (`gs://…`) passed to the analysis function.
    private func fetchSignedURL(for videoURL: URL, contentType: String) async throws -> (URL, String) {
        let appCheckToken = try await fetchAppCheckToken()
        let request = try Self.makeSignedURLRequest(
            endpoint: Endpoint.signedURL,
            videoURL: videoURL,
            contentType: contentType,
            userId: userId,
            appCheckToken: appCheckToken
        )

        let (data, response) = try await data(
            forBackendRequest: request,
            timeout: BackendTimeout.signedURL
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if let backendError = GCPError.fromBackendResponse(statusCode: http.statusCode, data: data) {
            throw backendError
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("getSignedUploadURL: HTTP \(http.statusCode) — \(body)")
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        guard let rawURL = decoded["signedUrl"],
              let signedURL = URL(string: rawURL),
              let gcsUri = decoded["gcsUri"] else {
            throw URLError(.cannotParseResponse)
        }
        return (signedURL, gcsUri)
    }

    /// Streams the video file to GCS with a PUT request.
    /// Uses an NSObject delegate shim to relay byte-level progress back to the
    /// main actor — the same pattern used by CaptureDelegate in CameraService.
    private func upload(fileURL: URL, to signedURL: URL, contentType: String, requestID: UUID) async throws {
        let progressDelegate = UploadProgressDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.setUploadState(.uploading(progress), for: requestID)
            }
        }
        // Use an ephemeral session so it has no inherited HTTP/3 alternative-service
        // cache from previous URLSession.shared requests. QUIC (HTTP/3) mid-stream
        // frame loss was dropping the GCS PUT at ~30% on some cellular networks.
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(
            configuration: config,
            delegate: progressDelegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            logger.error("GCS PUT: response was not HTTPURLResponse")
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("GCS PUT: HTTP \(http.statusCode) — \(body)")
            throw URLError(.badServerResponse)
        }
        logger.debug("GCS PUT: HTTP \(http.statusCode) — upload complete")
    }

    private func setUploadState(_ state: UploadState, for requestID: UUID) {
        guard requestID == currentRequestID else { return }
        uploadState = state
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        return false
    }

    private func triggerAnalysis(gcsUri: String, analysisRequestID: UUID) async throws -> CatAnalysis {
        let appCheckToken = try await fetchAppCheckToken()
        let request = try Self.makeAnalysisRequest(
            endpoint: Endpoint.analyse,
            gcsUri: gcsUri,
            userId: userId,
            analysisRequestID: analysisRequestID,
            appCheckToken: appCheckToken
        )

        let (data, response) = try await data(
            forBackendRequest: request,
            timeout: BackendTimeout.analysis
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if let backendError = GCPError.fromBackendResponse(statusCode: http.statusCode, data: data) {
            throw backendError
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("analyseVideo: HTTP \(http.statusCode) — \(body)")
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CatAnalysis.self, from: data)
    }

    private func fetchAppCheckToken() async throws -> String {
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: false)
            return token.token
        } catch {
            if isCancellation(error) {
                throw error
            }

            logger.error("App Check token fetch failed: \(error.localizedDescription, privacy: .public)")
            throw GCPError.appVerificationFailed
        }
    }

    private func data(
        forBackendRequest request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let config = Self.makeBackendSessionConfiguration(timeout: timeout)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    static func makeBackendSessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        config.waitsForConnectivity = true
        return config
    }

    static func makeSignedURLRequest(
        endpoint: URL,
        videoURL: URL,
        contentType: String,
        userId: String,
        appCheckToken: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: Header.contentType)
        request.setValue(appCheckToken, forHTTPHeaderField: Header.appCheck)
        let payload: [String: String] = [
            "filename":    videoURL.lastPathComponent,
            "contentType": contentType,
            "userId":      userId,
        ]
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    static func makeAnalysisRequest(
        endpoint: URL,
        gcsUri: String,
        userId: String,
        analysisRequestID: UUID,
        appCheckToken: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: Header.contentType)
        request.setValue(appCheckToken, forHTTPHeaderField: Header.appCheck)
        let payload: [String: String] = [
            "gcsUri": gcsUri,
            "userId": userId,
            "analysisRequestId": analysisRequestID.uuidString,
        ]
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
}

// MARK: - Error types

struct BackendErrorResponse: Decodable, Equatable {
    let code: String
    let message: String
    let limit: Int?
    let remaining: Int?
    let resetAt: String?
}

enum GCPError: LocalizedError, Equatable {
    case appVerificationFailed
    case quotaExceeded

    private static let appCheckUnauthorizedCode = "app_check_unauthorized"
    private static let dailyScanQuotaExceededCode = "daily_scan_quota_exceeded"

    static func fromBackendResponse(statusCode: Int, data: Data) -> GCPError? {
        guard let response = try? JSONDecoder().decode(BackendErrorResponse.self, from: data),
              let error = fromBackendError(statusCode: statusCode, code: response.code) else {
            return nil
        }

        return error
    }

    static func fromBackendError(statusCode: Int, code: String) -> GCPError? {
        switch (statusCode, code) {
        case (401, appCheckUnauthorizedCode):
            return .appVerificationFailed
        case (429, dailyScanQuotaExceededCode):
            return .quotaExceeded
        default:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .appVerificationFailed:
            return "We couldn't verify this CatVox build. Please relaunch the app and try again."
        case .quotaExceeded:
            return "Daily scan limit reached. Come back tomorrow."
        }
    }
}

private struct PipelinePhaseFailure: LocalizedError {
    let phase: GCPService.PipelinePhase
    let underlying: Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

// MARK: - Upload progress delegate (NSObject shim)

/// Isolated NSObject that forwards URLSession byte-progress callbacks to a
/// Swift closure. Mirrors the CaptureDelegate pattern in CameraService —
/// keeps NSObject out of the @Observable class to avoid init-accessor conflicts.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {

    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
