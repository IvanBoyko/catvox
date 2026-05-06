import Foundation

struct CatVoxLaunchConfiguration {
    let isUITesting: Bool
    let mockBackend: Bool
    let seedHistory: Bool
    let forceQuotaExceeded: Bool

    static var current: CatVoxLaunchConfiguration {
        CatVoxLaunchConfiguration(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    init(
        arguments: [String],
        environment: [String: String]
    ) {
        let arguments = Set(arguments)
        isUITesting = arguments.contains("-uiTesting") ||
            environment["CATVOX_UI_TESTING"] == "1"
        mockBackend = arguments.contains("-mockBackend") ||
            environment["CATVOX_MOCK_BACKEND"] == "1"
        seedHistory = arguments.contains("-seedHistory") ||
            environment["CATVOX_SEED_HISTORY"] == "1"
        forceQuotaExceeded = arguments.contains("-forceQuotaExceeded") ||
            environment["CATVOX_FORCE_QUOTA_EXCEEDED"] == "1"
    }
}
