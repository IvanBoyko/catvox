import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAppCheck

@main
struct CatVoxApp: App {

    private let launchConfiguration: CatVoxLaunchConfiguration
    @State private var quotaStore: ScanQuotaStore

    init() {
        let launchConfiguration = CatVoxLaunchConfiguration.current
        self.launchConfiguration = launchConfiguration

        if launchConfiguration.isUITesting {
            CatVoxUITestSupport.resetPersistentState()
        } else {
            Self.configureFirebase()
        }

        _quotaStore = State(
            initialValue: ScanQuotaStore(
                initialScansRemaining: launchConfiguration.forceQuotaExceeded ? 0 : nil
            )
        )
        AnalyticsService.configure()
        Self.prepareApplicationSupportDirectory()
    }

    var body: some Scene {
        WindowGroup {
            CatVoxRootView(launchConfiguration: launchConfiguration)
                .environment(quotaStore)
        }
        .modelContainer(for: SavedScan.self, inMemory: launchConfiguration.isUITesting)
    }

    private static func configureFirebase() {
        #if DEBUG
        let providerFactory = AppCheckDebugProviderFactory()
        #else
        let providerFactory = CatVoxAppCheckProviderFactory()
        #endif

        AppCheck.setAppCheckProviderFactory(providerFactory)
        FirebaseApp.configure()
    }

    private static func prepareApplicationSupportDirectory() {
        let fileManager = FileManager.default
        guard let supportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return
        }

        try? fileManager.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
    }
}

private struct CatVoxRootView: View {
    @Environment(\.modelContext) private var modelContext

    let launchConfiguration: CatVoxLaunchConfiguration

    var body: some View {
        ContentView()
            .task {
                CatVoxUITestSupport.seedIfNeeded(
                    configuration: launchConfiguration,
                    modelContext: modelContext
                )
            }
    }
}

private final class CatVoxAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
