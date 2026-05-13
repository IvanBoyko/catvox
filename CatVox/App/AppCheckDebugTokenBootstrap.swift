import Foundation

#if DEBUG
enum AppCheckDebugTokenBootstrap {
    static let preferredEnvironmentVariable = "AppCheckDebugToken"
    static let firebaseEnvironmentVariable = "FIRAAppCheckDebugToken"
    static let userDefaultsKey = "catvox.appCheckDebugToken"

    static func configure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        setEnvironment: (String, String) -> Void = { key, value in
            _ = setenv(key, value, 1)
        }
    ) {
        if let environmentToken = debugToken(from: environment) {
            userDefaults.set(environmentToken, forKey: userDefaultsKey)
            return
        }

        guard let storedToken = storedDebugToken(in: userDefaults) else {
            return
        }

        setEnvironment(preferredEnvironmentVariable, storedToken)
    }

    static func debugToken(from environment: [String: String]) -> String? {
        if let token = normalizedDebugToken(environment[preferredEnvironmentVariable]) {
            return token
        }

        return normalizedDebugToken(environment[firebaseEnvironmentVariable])
    }

    static func storedDebugToken(in userDefaults: UserDefaults = .standard) -> String? {
        normalizedDebugToken(userDefaults.string(forKey: userDefaultsKey))
    }

    static func normalizedDebugToken(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        let lowercased = token.lowercased()
        guard lowercased != "your-app-check-debug-token",
              lowercased != "replace-me",
              !lowercased.contains("placeholder"),
              !token.contains("$("),
              !token.contains("<"),
              !token.contains(">") else {
            return nil
        }

        return token
    }
}
#endif
