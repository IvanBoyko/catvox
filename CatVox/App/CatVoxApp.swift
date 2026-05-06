import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAppCheck

@main
struct CatVoxApp: App {

    @State private var quotaStore = ScanQuotaStore()

    init() {
        Self.configureFirebase()
        AnalyticsService.configure()
        Self.prepareApplicationSupportDirectory()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(quotaStore)
        }
        .modelContainer(for: SavedScan.self)
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

private final class CatVoxAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
