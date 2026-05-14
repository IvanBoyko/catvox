import Foundation

#if DEBUG
enum AppCheckDebugTokenBootstrap {
    static let preferredEnvironmentVariable = "AppCheckDebugToken"
    static let firebaseEnvironmentVariable = "FIRAAppCheckDebugToken"
    static let userDefaultsKey = "catvox.appCheckDebugToken"
    static let minimumTokenLength = 16

    /// Must run before `AppCheckDebugProviderFactory` creates a provider. The
    /// Firebase debug provider captures the process environment during init,
    /// and mutating `environ` later is unsafe around concurrent readers.
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

    static func clearStoredToken(in userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: userDefaultsKey)
    }

    static func normalizedDebugToken(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= minimumTokenLength,
              token.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

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
