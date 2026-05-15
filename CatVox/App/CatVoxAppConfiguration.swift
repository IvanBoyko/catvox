import Foundation

struct CatVoxAppConfiguration: Equatable {
    #if DEBUG
    private static let debugDefaultEnvironmentName = "dev"
    private static let debugDefaultSignedUploadURLEndpoint = URL(
        string: "https://getsigneduploadurl-pdkw5uifga-uc.a.run.app"
    )!
    private static let debugDefaultAnalyseVideoEndpoint = URL(
        string: "https://analysevideo-pdkw5uifga-uc.a.run.app"
    )!
    private static let debugDefaultPostHogHost = URL(string: "https://us.i.posthog.com")!
    #endif

    let environmentName: String
    let signedUploadURLEndpoint: URL
    let analyseVideoEndpoint: URL
    let postHogProjectToken: String?
    let postHogHost: URL

    static let current = loadCurrent()

    #if DEBUG
    init(
        environmentName: String = Self.debugDefaultEnvironmentName,
        signedUploadURLEndpoint: URL = Self.debugDefaultSignedUploadURLEndpoint,
        analyseVideoEndpoint: URL = Self.debugDefaultAnalyseVideoEndpoint,
        postHogProjectToken: String? = nil,
        postHogHost: URL = Self.debugDefaultPostHogHost
    ) {
        self.environmentName = Self.normalized(environmentName) ?? Self.debugDefaultEnvironmentName
        self.signedUploadURLEndpoint = signedUploadURLEndpoint
        self.analyseVideoEndpoint = analyseVideoEndpoint
        self.postHogProjectToken = Self.normalized(postHogProjectToken)
        self.postHogHost = postHogHost
    }
    #endif

    init(
        infoDictionary: [String: Any],
        environment: [String: String] = [:],
        allowDebugDefaults: Bool = false
    ) throws {
        environmentName = try Self.requiredValue(
            environment,
            keys: ["CATVOX_ENVIRONMENT"],
            infoDictionary: infoDictionary,
            infoKeys: ["CatVoxEnvironment"],
            fallback: Self.debugFallbackEnvironmentName(allowDebugDefaults: allowDebugDefaults)
        )

        signedUploadURLEndpoint = try Self.requiredURLValue(
            environment,
            keys: ["CATVOX_SIGNED_UPLOAD_URL_ENDPOINT"],
            infoDictionary: infoDictionary,
            infoKeys: ["CatVoxSignedUploadURLEndpoint"],
            fallback: Self.debugFallbackSignedUploadURLEndpoint(allowDebugDefaults: allowDebugDefaults)
        )

        analyseVideoEndpoint = try Self.requiredURLValue(
            environment,
            keys: ["CATVOX_ANALYSE_VIDEO_ENDPOINT"],
            infoDictionary: infoDictionary,
            infoKeys: ["CatVoxAnalyseVideoEndpoint"],
            fallback: Self.debugFallbackAnalyseVideoEndpoint(allowDebugDefaults: allowDebugDefaults)
        )

        postHogProjectToken = Self.value(
            environment,
            keys: ["CATVOX_POSTHOG_PROJECT_TOKEN"],
            infoDictionary: infoDictionary,
            infoKeys: ["CatVoxPostHogProjectToken", "PostHogProjectToken"]
        )

        postHogHost = try Self.requiredURLValue(
            environment,
            keys: ["CATVOX_POSTHOG_HOST"],
            infoDictionary: infoDictionary,
            infoKeys: ["CatVoxPostHogHost", "PostHogHost"],
            fallback: Self.debugFallbackPostHogHost(allowDebugDefaults: allowDebugDefaults)
        )
    }

    #if DEBUG
    init(
        infoDictionary: [String: Any],
        environment: [String: String] = [:]
    ) {
        do {
            try self.init(
                infoDictionary: infoDictionary,
                environment: environment,
                allowDebugDefaults: true
            )
        } catch {
            assertionFailure("Invalid CatVox app configuration: \(error)")
            self.init()
        }
    }
    #endif

    private static func value(
        _ environment: [String: String],
        keys: [String],
        infoDictionary: [String: Any],
        infoKeys: [String]
    ) -> String? {
        for key in keys {
            if let value = normalized(environment[key]) {
                return value
            }
        }

        for infoKey in infoKeys {
            if let value = normalized(infoDictionary[infoKey] as? String) {
                return value
            }
        }

        return nil
    }

    private static func requiredValue(
        _ environment: [String: String],
        keys: [String],
        infoDictionary: [String: Any],
        infoKeys: [String],
        fallback: String?
    ) throws -> String {
        if let value = value(
            environment,
            keys: keys,
            infoDictionary: infoDictionary,
            infoKeys: infoKeys
        ) {
            return value
        }

        if let fallback {
            return fallback
        }

        throw ConfigurationError.missingValue(infoKeys[0])
    }

    private static func requiredURLValue(
        _ environment: [String: String],
        keys: [String],
        infoDictionary: [String: Any],
        infoKeys: [String],
        fallback: URL?
    ) throws -> URL {
        guard let value = value(
            environment,
            keys: keys,
            infoDictionary: infoDictionary,
            infoKeys: infoKeys
        ) else {
            if let fallback {
                return fallback
            }
            throw ConfigurationError.missingValue(infoKeys[0])
        }

        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil else {
            if let fallback {
                assertionFailure("Invalid URL for \(infoKeys[0]): \(value)")
                return fallback
            }
            throw ConfigurationError.invalidURL(infoKeys[0], value)
        }

        return url
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private static func loadCurrent() -> CatVoxAppConfiguration {
        do {
            return try CatVoxAppConfiguration(
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                environment: ProcessInfo.processInfo.environment,
                allowDebugDefaults: runtimeAllowsDebugDefaults
            )
        } catch {
            #if DEBUG
            assertionFailure("Invalid CatVox app configuration: \(error)")
            return CatVoxAppConfiguration()
            #else
            fatalError("Invalid CatVox app configuration: \(error)")
            #endif
        }
    }

    private static var runtimeAllowsDebugDefaults: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func debugFallbackEnvironmentName(allowDebugDefaults: Bool) -> String? {
        #if DEBUG
        return allowDebugDefaults ? debugDefaultEnvironmentName : nil
        #else
        return nil
        #endif
    }

    private static func debugFallbackSignedUploadURLEndpoint(allowDebugDefaults: Bool) -> URL? {
        #if DEBUG
        return allowDebugDefaults ? debugDefaultSignedUploadURLEndpoint : nil
        #else
        return nil
        #endif
    }

    private static func debugFallbackAnalyseVideoEndpoint(allowDebugDefaults: Bool) -> URL? {
        #if DEBUG
        return allowDebugDefaults ? debugDefaultAnalyseVideoEndpoint : nil
        #else
        return nil
        #endif
    }

    private static func debugFallbackPostHogHost(allowDebugDefaults: Bool) -> URL? {
        #if DEBUG
        return allowDebugDefaults ? debugDefaultPostHogHost : nil
        #else
        return nil
        #endif
    }
}

private enum ConfigurationError: Error, CustomStringConvertible, Equatable {
    case missingValue(String)
    case invalidURL(String, String)

    var description: String {
        switch self {
        case .missingValue(let key):
            return "Missing required Info.plist value: \(key)"
        case .invalidURL(let key, let value):
            return "Invalid URL for \(key): \(value)"
        }
    }
}
