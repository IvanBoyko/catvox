import Photos
import SwiftUI
import SwiftData
import UIKit
import os

/// The centrepiece of the CatVox experience.
///
/// Two initialisation paths:
///   `init(analysis:)`  — Dev-preview / Phase 1.  Analysis is supplied directly;
///                        no upload occurs and the result UI springs in immediately.
///   `init(videoURL:)`  — Normal recording path.  GCPService drives the upload
///                        pipeline; the result UI replaces the loading card once
///                        analysis is returned from the backend (or mock).
///   `init(savedScan:)` — Reopened local history item; result UI uses persisted
///                        data without re-uploading or re-analysing the clip.
///
/// Layout (bottom-to-top):
///   1. Full-screen animated gradient background (persona-tinted)
///   2. Soft vignette
///   3. ThoughtBubbleView / UploadProgressView — springs in after upload
///   4. Bottom panel (PersonaBadge + ExpertInsightsDrawer + Done CTA)
///   5. Top bar with a dismiss control only while the result is incomplete
///
/// See TRD §5.1 and PROMPT.md §2 for the full specification.
struct ResultView: View {

    private enum ShareExportAction {
        case saveToPhotos
        case shareSheet

        var analyticsValue: String {
            switch self {
            case .saveToPhotos:
                return "save_to_photos"
            case .shareSheet:
                return "share_sheet"
            }
        }
    }

    private struct ShareSheetItem: Identifiable {
        let id = UUID()
        let url: URL
        let scanID: UUID
    }

    private enum PhotoSaveError: Error {
        case permissionDenied
    }

    @Environment(\.dismiss)        private var dismiss
    @Environment(\.modelContext)   private var modelContext
    @Environment(ScanQuotaStore.self) private var quotaStore

    /// Becomes non-nil once analysis is available — immediately for the dev
    /// path, or after `gcpService` completes for the recording path.
    @State private var viewModel: ResultViewModel?

    /// Active only when `videoURL` is non-nil.
    @State private var gcpService = GCPService()

    /// Error state for the retry alert.
    @State private var showRetryAlert = false
    @State private var failureTitle = "Processing Failed"
    @State private var failureMessage  = ""
    @State private var canRetryFailure = true
    @State private var persistenceMessage = ""
    @State private var showPersistenceAlert = false
    @State private var backgroundVideoURL: URL?
    @State private var backgroundAmbientImageURL: URL?
    @State private var backgroundPlaybackMessage: String?
    @State private var renderedShareVideoURL: URL?
    @State private var shareProgressMessage: String?
    @State private var exportNoticeMessage: String?
    @State private var exportAlertMessage = ""
    @State private var showExportAlert = false
    @State private var shareSheetItem: ShareSheetItem?
    @State private var shareRenderTask: Task<Void, Never>?
    @State private var photoSaveTask: Task<Void, Never>?

    private let shareLogger = Logger(subsystem: "com.kathelix.catvox", category: "ResultShare")

    /// Set at init; nil in dev-preview mode (analysis provided directly).
    private let videoURL: URL?
    private let sourceType: ScanSourceType?

    // MARK: - Init

    /// Dev-preview / Phase 1: analysis is provided directly, no upload.
    init(analysis: CatAnalysis) {
        videoURL = nil
        sourceType = nil
        _backgroundVideoURL = State(initialValue: nil)
        _backgroundAmbientImageURL = State(initialValue: nil)
        _viewModel = State(initialValue: ResultViewModel(analysis: analysis))
    }

    /// Normal recording path: upload is triggered on appear.
    init(videoURL: URL, sourceType: ScanSourceType) {
        self.videoURL = videoURL
        self.sourceType = sourceType
        _backgroundVideoURL = State(initialValue: videoURL)
        _backgroundAmbientImageURL = State(initialValue: nil)
        _viewModel = State(initialValue: nil)
    }

    /// Local-history path: result is reconstructed from persisted state.
    init(savedScan: SavedScan) {
        videoURL = ScanHistoryStore.originalVideoURL(for: savedScan)
        sourceType = savedScan.sourceType
        _backgroundVideoURL = State(initialValue: ScanHistoryStore.originalVideoURL(for: savedScan))
        _backgroundAmbientImageURL = State(initialValue: ScanHistoryStore.thumbnailURL(for: savedScan))
        _viewModel = State(initialValue: ResultViewModel(analysis: savedScan.analysis))
    }

    // MARK: - Derived

    /// Falls back to `.grumpyBoss` while the upload is pending so the
    /// background gradient always has a valid persona to render.
    private var activePersona: CatPersona {
        viewModel?.persona ?? .grumpyBoss
    }

    private var showsCompletedResult: Bool {
        viewModel != nil
    }

    private var isShareExportInFlight: Bool {
        shareRenderTask != nil || photoSaveTask != nil || shareProgressMessage != nil
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("result.screen")

            // ── 1. Background ──────────────────────────────────────────────
            backgroundView

            // ── 2. Targeted readability scrims ────────────────────────────
            chromeScrims

            // ── 3 + 4 + 5. Content ─────────────────────────────────────────
            VStack(spacing: 0) {
                topBar
                    .padding(.top, -26)

                if let backgroundPlaybackMessage {
                    backgroundPlaybackNotice(backgroundPlaybackMessage)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                if let shareProgressMessage {
                    shareProgressNotice(shareProgressMessage)
                        .padding(.horizontal, 20)
                        .padding(.top, backgroundPlaybackMessage == nil ? 12 : 8)
                } else if let exportNoticeMessage {
                    exportNotice(exportNoticeMessage)
                        .padding(.horizontal, 20)
                        .padding(.top, backgroundPlaybackMessage == nil ? 12 : 8)
                }

                Spacer()

                if let viewModel {
                    resultContent(viewModel)
                } else if gcpService.uploadState == .quotaExceeded {
                    quotaExceededContent
                } else {
                    loadingContent
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear(perform: handleAppear)
        .onChange(of: gcpService.uploadState) { _, state in handleUploadState(state) }
        .onDisappear {
            shareRenderTask?.cancel()
        }
        .alert(failureTitle, isPresented: $showRetryAlert) {
            if canRetryFailure {
                Button("Retry") {
                    AnalyticsService.capture(.analysisRetryTapped)
                    if let url = videoURL { gcpService.retry(videoAt: url) }
                }
            }
            Button("Cancel", role: .cancel) { dismissResult() }
        } message: {
            Text(failureMessage)
        }
        .alert("History Save Failed", isPresented: $showPersistenceAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text(persistenceMessage)
        }
        .alert("Share Export", isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
        .sheet(item: $shareSheetItem) { item in
            ActivityView(activityItems: [item.url]) { activityType, completed, error in
                handleShareSheetCompletion(
                    scanID: item.scanID,
                    activityType: activityType,
                    completed: completed,
                    error: error
                )
            }
        }
    }

    // MARK: - Content branches

    @ViewBuilder
    private var backgroundView: some View {
        if let backgroundVideoURL, backgroundPlaybackMessage == nil {
            ResultVideoBackdrop(
                videoURL: backgroundVideoURL,
                ambientImageURL: backgroundAmbientImageURL
            ) { failedURL, message in
                guard failedURL == self.backgroundVideoURL else { return }
                backgroundPlaybackMessage = message
            }
            .ignoresSafeArea()
        } else {
            AnimatedVideoBackground(persona: activePersona)
                .ignoresSafeArea()
        }
    }

    /// Shown when the daily free scan quota is exhausted (HTTP 429).
    private var quotaExceededContent: some View {
        QuotaExceededView { dismiss() }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
            .transition(.opacity)
    }

    /// Shown while GCPService is working. Sits in the same vertical zone
    /// as the thought bubble so the transition feels continuous.
    private var loadingContent: some View {
        UploadProgressView(state: gcpService.uploadState)
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
            .transition(.opacity)
            .accessibilityIdentifier("upload.progressCard")
    }

    /// Full result UI — mirrors the original single-path layout.
    @ViewBuilder
    private func resultContent(_ vm: ResultViewModel) -> some View {
        if vm.thoughtBubbleVisible {
            ThoughtBubbleView(
                analysis: vm.analysis,
                persona:  vm.persona
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.82, anchor: .bottom)
                               .combined(with: .opacity),
                    removal:   .opacity
                )
            )
        }

        if vm.panelVisible {
            bottomPanel(vm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack(alignment: .top) {
            if !showsCompletedResult {
                HStack {
                    Button { dismissResult() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(4)

                    Spacer()
                }
            }

            HStack {
                Spacer()

                Text("CatVox")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(3)
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom panel

    private func bottomPanel(_ vm: ResultViewModel) -> some View {
        VStack(spacing: 12) {
            PersonaBadgeView(
                emotion:    vm.analysis.primaryEmotion,
                persona:    vm.persona,
                confidence: vm.analysis.confidenceScore
            )

            ExpertInsightsDrawer(
                analysis:   vm.analysis,
                isExpanded: Binding(
                    get: { vm.isInsightsExpanded },
                    set: { vm.isInsightsExpanded = $0 }
                )
            )

            if backgroundVideoURL != nil {
                shareActions(vm)
            }

            doneButton(vm)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }

    private func backgroundPlaybackNotice(_ message: String) -> some View {
        statusNotice(message, systemImage: "exclamationmark.triangle.fill")
    }

    private func exportNotice(_ message: String) -> some View {
        statusNotice(message, systemImage: "checkmark.circle.fill")
    }

    private func statusNotice(_ message: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))

            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.84))
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var chromeScrims: some View {
        ZStack {
            Color.black.opacity(0.05)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.42), location: 0.00),
                        .init(color: .black.opacity(0.20), location: 0.55),
                        .init(color: .black.opacity(0.00), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 168)

                Spacer(minLength: 0)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.00), location: 0.00),
                        .init(color: .black.opacity(0.14), location: 0.24),
                        .init(color: .black.opacity(0.28), location: 0.62),
                        .init(color: .black.opacity(0.42), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 320)
            }
        }
        .ignoresSafeArea()
    }

    private func doneButton(_ vm: ResultViewModel) -> some View {
        Button {
            guard !isShareExportInFlight else { return }
            dismissResult()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .fontWeight(.semibold)
                Text("Done")
                    .fontWeight(.bold)
            }
            .font(.subheadline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        vm.persona.accentColor,
                        vm.persona.accentColor.opacity(0.78),
                    ],
                    startPoint: .leading,
                    endPoint:   .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .disabled(isShareExportInFlight)
        .opacity(isShareExportInFlight ? 0.55 : 1)
        .accessibilityIdentifier("result.doneButton")
    }

    private func shareActions(_ vm: ResultViewModel) -> some View {
        HStack(spacing: 12) {
            Button {
                startShareExport(.saveToPhotos, analysis: vm.analysis)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    }
            }
            .disabled(isShareExportInFlight)

            Button {
                startShareExport(.shareSheet, analysis: vm.analysis)
            } label: {
                Label("Share Video", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        CatVoxTheme.brandGradient,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .disabled(isShareExportInFlight)
        }
    }

    private func shareProgressNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.88))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    // MARK: - Event handlers

    private func handleAppear() {
        backgroundPlaybackMessage = nil

        if viewModel != nil {
            viewModel?.onAppear()
        } else if let url = videoURL, gcpService.uploadState == .idle {
            let launchConfiguration = CatVoxLaunchConfiguration.current
            gcpService.mockMode = launchConfiguration.isUITesting || launchConfiguration.mockBackend
            gcpService.forceQuotaExceeded = launchConfiguration.forceQuotaExceeded
            // Recording path — kick off the upload pipeline.
            gcpService.uploadAndAnalyse(videoAt: url)
        }
    }

    private func dismissResult() {
        guard !isShareExportInFlight else { return }

        if !showsCompletedResult {
            gcpService.reset()
        }
        shareRenderTask?.cancel()
        dismiss()
    }

    private func handleUploadState(_ state: GCPService.UploadState) {
        switch state {
        case .complete(let analysis):
            Task { @MainActor in
                await handleCompletedAnalysis(analysis)
            }

        case .quotaExceeded:
            quotaStore.markExhausted()
            AnalyticsService.capture(.quotaExceeded)
            AnalyticsService.capture(.quotaCardShown, properties: ["trigger": "server_quota"])

        case .appVerificationFailed:
            failureTitle = "Verification Failed"
            failureMessage = GCPError.appVerificationFailed.localizedDescription
            canRetryFailure = false
            showRetryAlert = true
            AnalyticsService.capture(
                .analysisFailed,
                properties: ["error_message": failureMessage]
            )

        case .failed(let phase, let message):
            failureTitle = phase.failureTitle
            failureMessage = message
            canRetryFailure = true
            showRetryAlert = true
            AnalyticsService.capture(.analysisFailed, properties: ["error_message": message])

        default:
            break
        }
    }

    @MainActor
    private func handleCompletedAnalysis(_ analysis: CatAnalysis) async {
        quotaStore.recordScan()

        guard let videoURL, let sourceType else {
            AnalyticsService.capture(.analysisCompleted, properties: [
                "persona_type": analysis.personaType,
                "primary_emotion": analysis.primaryEmotion,
                "confidence_score": analysis.confidenceScore,
            ])
            let vm = ResultViewModel(analysis: analysis)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                viewModel = vm
            }
            Task { @MainActor in vm.onAppear() }
            return
        }

        do {
            let savedScan = try await ScanHistoryStore.saveScan(
                from: videoURL,
                sourceType: sourceType,
                analysis: analysis,
                in: modelContext
            )

            backgroundVideoURL = ScanHistoryStore.originalVideoURL(for: savedScan)
            backgroundAmbientImageURL = ScanHistoryStore.thumbnailURL(for: savedScan)
            backgroundPlaybackMessage = nil

            AnalyticsService.capture(.analysisCompleted, properties: [
                "persona_type": analysis.personaType,
                "primary_emotion": analysis.primaryEmotion,
                "confidence_score": analysis.confidenceScore,
                "source_type": sourceType.rawValue,
            ])
            let vm = ResultViewModel(analysis: analysis)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                viewModel = vm
            }
            Task { @MainActor in vm.onAppear() }
        } catch {
            persistenceMessage = "We couldn't save this scan to local history."
            showPersistenceAlert = true
        }
    }

    private func startShareExport(_ action: ShareExportAction, analysis: CatAnalysis) {
        guard !isShareExportInFlight else { return }

        if let renderedShareVideoURL, FileManager.default.fileExists(atPath: renderedShareVideoURL.path) {
            performShareAction(action, analysis: analysis, using: renderedShareVideoURL)
            return
        }

        if let cachedOutputURL = try? ShareVideoRenderer.existingRenderedVideoURL(for: analysis.id),
           FileManager.default.fileExists(atPath: cachedOutputURL.path) {
            renderedShareVideoURL = cachedOutputURL
            performShareAction(action, analysis: analysis, using: cachedOutputURL)
            return
        }

        guard let backgroundVideoURL, FileManager.default.fileExists(atPath: backgroundVideoURL.path) else {
            exportAlertMessage = "We couldn't find the saved clip for this export."
            showExportAlert = true
            return
        }

        shareRenderTask?.cancel()
        shareProgressMessage = "Preparing share video..."
        AnalyticsService.capture(
            .shareExportStarted,
            properties: [
                "action": action.analyticsValue,
                "scan_id": analysis.id.uuidString,
            ]
        )

        let request = ShareVideoRenderer.Request(
            scanID: analysis.id,
            sourceVideoURL: backgroundVideoURL,
            analysis: analysis
        )

        shareRenderTask = Task {
            do {
                let outputURL = try await ShareVideoRenderer.renderVideo(for: request)
                try Task.checkCancellation()
                await MainActor.run {
                    renderedShareVideoURL = outputURL
                    shareProgressMessage = nil
                    shareRenderTask = nil
                    performShareAction(action, analysis: analysis, using: outputURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    shareProgressMessage = nil
                    shareRenderTask = nil
                }
            } catch {
                shareLogger.error("share render failed scan=\(analysis.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    AnalyticsService.capture(
                        .shareExportRenderFailed,
                        properties: [
                            "action": action.analyticsValue,
                            "scan_id": analysis.id.uuidString,
                            "error_type": String(describing: type(of: error)),
                        ]
                    )
                    shareProgressMessage = nil
                    shareRenderTask = nil
                    exportAlertMessage = "We couldn't render the share video."
                    showExportAlert = true
                }
            }
        }
    }

    private func performShareAction(_ action: ShareExportAction, analysis: CatAnalysis, using outputURL: URL) {
        switch action {
        case .shareSheet:
            AnalyticsService.capture(
                .shareSheetOpened,
                properties: ["scan_id": analysis.id.uuidString]
            )
            shareSheetItem = ShareSheetItem(url: outputURL, scanID: analysis.id)

        case .saveToPhotos:
            shareProgressMessage = "Saving to Photos..."

            photoSaveTask = Task {
                do {
                    try await saveRenderedVideoToPhotos(outputURL)
                    try Task.checkCancellation()
                    await MainActor.run {
                        AnalyticsService.capture(
                            .scanSavedToPhotos,
                            properties: ["scan_id": analysis.id.uuidString]
                        )
                        shareProgressMessage = nil
                        photoSaveTask = nil
                        showTransientExportNotice("Saved to Photos")
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        shareProgressMessage = nil
                        photoSaveTask = nil
                    }
                } catch {
                    shareLogger.error("save to photos failed url=\(outputURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    await MainActor.run {
                        if error is PhotoSaveError {
                            AnalyticsService.capture(
                                .photosPermissionDenied,
                                properties: ["scan_id": analysis.id.uuidString]
                            )
                        }
                        AnalyticsService.capture(
                            .shareSaveFailed,
                            properties: [
                                "scan_id": analysis.id.uuidString,
                                "error_type": String(describing: type(of: error)),
                            ]
                        )
                        shareProgressMessage = nil
                        photoSaveTask = nil
                        exportAlertMessage = "We couldn't save the share video to Photos."
                        showExportAlert = true
                    }
                }
            }
        }
    }

    private func saveRenderedVideoToPhotos(_ outputURL: URL) async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus: PHAuthorizationStatus

        if currentStatus == .notDetermined {
            resolvedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedStatus = currentStatus
        }

        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw PhotoSaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
        }
    }

    private func handleShareSheetCompletion(
        scanID: UUID,
        activityType: UIActivity.ActivityType?,
        completed: Bool,
        error: Error?
    ) {
        var properties: [String: Any] = [
            "scan_id": scanID.uuidString,
            "activity_type": activityType?.rawValue ?? "unknown",
        ]
        if let error {
            properties["error_type"] = String(describing: type(of: error))
        }

        if completed {
            AnalyticsService.capture(.scanShared, properties: properties)
        } else {
            AnalyticsService.capture(.shareSheetCancelled, properties: properties)
        }
    }

    private func showTransientExportNotice(_ message: String) {
        exportNoticeMessage = message

        Task {
            try? await Task.sleep(for: .seconds(2.2))
            await MainActor.run {
                if exportNoticeMessage == message {
                    exportNoticeMessage = nil
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Grumpy Boss") {
    ResultView(analysis: MockAnalysisService.sampleAnalysis)
        .environment(ScanQuotaStore())
        .modelContainer(for: SavedScan.self, inMemory: true)
}

#Preview("Existential Philosopher") {
    ResultView(analysis: MockAnalysisService.allSamples[1])
        .environment(ScanQuotaStore())
        .modelContainer(for: SavedScan.self, inMemory: true)
}

#Preview("Chaotic Hunter") {
    ResultView(analysis: MockAnalysisService.allSamples[2])
        .environment(ScanQuotaStore())
        .modelContainer(for: SavedScan.self, inMemory: true)
}

#Preview("Upload in Progress") {
    ResultView(videoURL: URL(fileURLWithPath: "/dev/null"), sourceType: .recorded)
        .environment(ScanQuotaStore())
        .modelContainer(for: SavedScan.self, inMemory: true)
}
