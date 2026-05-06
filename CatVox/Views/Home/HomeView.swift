import SwiftUI
import SwiftData

private struct PendingResultClip: Identifiable {
    let id = UUID()
    let url: URL
    let sourceType: ScanSourceType
}

struct HomeView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ScanQuotaStore.self) private var quotaStore
    @Query(sort: \SavedScan.createdAt, order: .forward) private var savedScans: [SavedScan]

    @State private var showSourceChoice = false
    @State private var showPhotoPicker  = false
    @State private var showRecording    = false
    @State private var showQuotaCard    = false
    @State private var showPhotoNotice  = false
    @State private var photoNoticeText  = ""
    @State private var activeResultClip: PendingResultClip?
    @State private var selectedSavedScan: SavedScan?
    @State private var photoClipToAnalyse: URL?
    @State private var recordedClipToAnalyse: URL?
    @State private var pendingDeletion: SavedScan?
    @State private var historyErrorMessage = ""
    @State private var showHistoryError = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()

            VStack(spacing: 24) {
                logoSection
                    .padding(.top, 40)
                    .padding(.horizontal, 24)

                historySection

                ctaSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
        }
        .overlay {
            ZStack {
                if showQuotaCard {
                    quotaOverlay
                }

                if showSourceChoice && usesUITestSourceChoiceOverlay {
                    uiTestSourceChoiceOverlay
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Choose Video Source",
            isPresented: sourceChoiceDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Record New Video") {
                chooseRecordSource()
            }
            .accessibilityIdentifier("source.recordNewVideoButton")

            Button("Choose from Photos") {
                choosePhotosSource()
            }
            .accessibilityIdentifier("source.chooseFromPhotosButton")

            Button("Cancel", role: .cancel) {
                showSourceChoice = false
            }
            .accessibilityIdentifier("source.cancelButton")
        } message: {
            Text("Start with a new recording or pick an existing clip.")
        }
        .sheet(isPresented: $showPhotoPicker, onDismiss: presentPendingPhotoClipIfReady) {
            HomeVideoPicker { outcome in
                switch outcome {
                case .cancelled:
                    showPhotoPicker = false

                case .success(let videoURL):
                    queuePhotoClipForAnalysis(videoURL)

                case .failure(let message):
                    photoNoticeText = message
                    showPhotoNotice = true
                    showPhotoPicker = false
                }
            }
        }
        .fullScreenCover(isPresented: $showRecording) {
            RecordingView { recordedURL in
                recordedClipToAnalyse = recordedURL
                showRecording = false
            }
        }
        .fullScreenCover(item: $activeResultClip) { clip in
            ResultView(videoURL: clip.url, sourceType: clip.sourceType)
                .id(clip.id)
        }
        .fullScreenCover(item: $selectedSavedScan) { savedScan in
            ResultView(savedScan: savedScan)
                .id(savedScan.id)
        }
        .onChange(of: showRecording) { _, isShowing in
            if !isShowing, let recordedClipToAnalyse {
                activeResultClip = PendingResultClip(url: recordedClipToAnalyse, sourceType: .recorded)
                self.recordedClipToAnalyse = nil
            }
        }
        .alert("Photos Import", isPresented: $showPhotoNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoNoticeText)
        }
        .alert("Delete Scan?", isPresented: deleteAlertPresented) {
            Button("Delete", role: .destructive) {
                deletePendingScan()
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the scan from CatVox history and deletes the CatVox-owned local clip.")
        }
        .alert("History Error", isPresented: $showHistoryError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(historyErrorMessage)
        }
    }

    private var quotaOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            QuotaExceededView { showQuotaCard = false }
                .padding(.horizontal, 20)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showQuotaCard)
    }

    private var uiTestSourceChoiceOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 12) {
                Button("Record New Video") {
                    chooseRecordSource()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(CatVoxTheme.brandGradient, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("source.recordNewVideoButton")

                Button("Choose from Photos") {
                    choosePhotosSource()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("source.chooseFromPhotosButton")

                Button("Cancel") {
                    showSourceChoice = false
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.vertical, 8)
                .accessibilityIdentifier("source.cancelButton")
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
        }
    }

    private var sourceChoiceDialogPresented: Binding<Bool> {
        Binding(
            get: { showSourceChoice && !usesUITestSourceChoiceOverlay },
            set: { isPresented in
                if !isPresented {
                    showSourceChoice = false
                }
            }
        )
    }

    private var usesUITestSourceChoiceOverlay: Bool {
        CatVoxLaunchConfiguration.current.isUITesting
    }

    private func chooseRecordSource() {
        showSourceChoice = false
        AnalyticsService.capture(.scanSourceChosen, properties: ["source": "record"])
        showRecording = true
    }

    private func choosePhotosSource() {
        showSourceChoice = false
        AnalyticsService.capture(.scanSourceChosen, properties: ["source": "photos"])
        AnalyticsService.capture(.photosPickerOpened)
        showPhotoPicker = true
    }

    private var logoSection: some View {
        VStack(spacing: 10) {
            Image("HomeAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            Text("CatVox")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Text("Powered by Kathelix")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .tracking(2)
        }
    }

    private var historySection: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    if savedScans.isEmpty {
                        emptyHistoryCard
                    } else {
                        ForEach(savedScans) { scan in
                            let index = savedScans.firstIndex { $0.id == scan.id } ?? 0
                            SavedScanRow(
                                scan: scan,
                                openAccessibilityIdentifier: "home.historyItem.\(index)",
                                onOpen: { open(scan) },
                                onDelete: { pendingDeletion = scan }
                            )
                            .id(scan.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("home.historyList")
            .onAppear {
                scrollToLatestScan(using: proxy, animated: false)
            }
            .onChange(of: savedScans.last?.id) { _, _ in
                scrollToLatestScan(using: proxy, animated: true)
            }
        }
    }

    private var emptyHistoryCard: some View {
        VStack(spacing: 10) {
            Text("No scans yet")
                .font(.headline)
                .foregroundStyle(.white)

            Text("Your completed cat scans will appear here.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier("home.emptyHistory")
    }

    private var ctaSection: some View {
        VStack(spacing: 12) {
            Button {
                if quotaStore.scansRemaining > 0 {
                    showSourceChoice = true
                } else {
                    AnalyticsService.capture(.quotaCardShown, properties: ["trigger": "home_local_quota"])
                    showQuotaCard = true
                }
            } label: {
                Label("Read My Cat", systemImage: "video.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(
                        CatVoxTheme.brandGradient,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .accessibilityIdentifier("home.readMyCatButton")

            Text(quotaLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .accessibilityIdentifier("home.quotaStatus")
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var quotaLabel: String {
        let n = quotaStore.scansRemaining
        return "\(n) free \(n == 1 ? "scan" : "scans") remaining today"
    }

    private func scrollToLatestScan(using proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = savedScans.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private func queuePhotoClipForAnalysis(_ videoURL: URL) {
        photoClipToAnalyse = videoURL

        if showPhotoPicker {
            showPhotoPicker = false
        } else {
            presentPendingPhotoClipIfReady()
        }
    }

    private func presentPendingPhotoClipIfReady() {
        guard let photoClipToAnalyse else { return }
        activeResultClip = PendingResultClip(url: photoClipToAnalyse, sourceType: .photos)
        self.photoClipToAnalyse = nil
    }

    private func open(_ scan: SavedScan) {
        let videoURL = ScanHistoryStore.originalVideoURL(for: scan)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            historyErrorMessage = "We couldn't find the saved clip for this scan."
            showHistoryError = true
            return
        }

        selectedSavedScan = scan
    }

    private func deletePendingScan() {
        guard let pendingDeletion else { return }

        let personaType = pendingDeletion.personaType
        do {
            try ScanHistoryStore.deleteScan(pendingDeletion, from: modelContext)
            AnalyticsService.capture(.scanDeleted, properties: ["persona_type": personaType])
        } catch {
            historyErrorMessage = "We couldn't delete this scan. Please try again."
            showHistoryError = true
        }

        self.pendingDeletion = nil
    }
}

#Preview {
    HomeView()
        .environment(ScanQuotaStore())
        .modelContainer(for: SavedScan.self, inMemory: true)
}
