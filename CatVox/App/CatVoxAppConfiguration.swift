import Foundation

struct CatVoxAppConfiguration: Equatable {
    static let defaultEnvironmentName = "dev"
    static let defaultSignedUploadURLEndpoint = URL(
        string: "https://getsigneduploadurl-pdkw5uifga-uc.a.run.app"
    )!
    static let defaultAnalyseVideoEndpoint = URL(
        string: "https://analysevideo-pdkw5uifga-uc.a.run.app"
    )!
    static let defaultPostHogHost = URL(string: "https://us.i.posthog.com")!

    let environmentName: String
    let signedUploadURLEndpoint: URL
    let analyseVideoEndpoint: URL
    let postHogProjectToken: String?
    let postHogHost: URL

    static var current: CatVoxAppConfiguration {
        CatVoxAppConfiguration(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment
        )
    }

    init(
        environmentName: String = Self.defaultEnvironmentName,
        signedUploadURLEndpoint: URL = Self.defaultSignedUploadURLEndpoint,
        analyseVideoEndpoint: URL = Self.defaultAnalyseVideoEndpoint,
        postHogProjectToken: String? = nil,
        postHogHost: URL = Self.defaultPostHogHost
    ) {
        self.environmentName = Self.normalized(environmentName) ?? Self.defaultEnvironmentName
        self.signedUploadURLEndpoint = signedUploadURLEndpoint
        self.analyseVideoEndpoint = analyseVideoEndpoint
        self.postHogProjectToken = Self.normalized(postHogProjectToken)
        self.postHogHost = postHogHost
    }

    init(
        infoDictionary: [String: Any],
        environment: [String: String] = [:]
    ) {
        environmentName = Self.value(
            environment,
            keys: ["CATVOX_ENVIRONMENT"],
            infoDictionary: infoDictionary,
            infoKey: "CatVoxEnvironment"
        ) ?? Self.defaultEnvironmentName

        signedUploadURLEndpoint = Self.urlValue(
            environment,
            keys: ["CATVOX_SIGNED_UPLOAD_URL_ENDPOINT", "CATVOX_SIGNED_URL_ENDPOINT"],
            infoDictionary: infoDictionary,
            infoKey: "CatVoxSignedUploadURLEndpoint",
            fallback: Self.defaultSignedUploadURLEndpoint
        )

        analyseVideoEndpoint = Self.urlValue(
            environment,
            keys: ["CATVOX_ANALYSE_VIDEO_ENDPOINT", "CATVOX_ANALYSE_ENDPOINT"],
            infoDictionary: infoDictionary,
            infoKey: "CatVoxAnalyseVideoEndpoint",
            fallback: Self.defaultAnalyseVideoEndpoint
        )

        postHogProjectToken = Self.value(
            environment,
            keys: ["CATVOX_POSTHOG_PROJECT_TOKEN", "POSTHOG_PROJECT_TOKEN"],
            infoDictionary: infoDictionary,
            infoKey: "PostHogProjectToken"
        )

        postHogHost = Self.urlValue(
            environment,
            keys: ["CATVOX_POSTHOG_HOST", "POSTHOG_HOST"],
            infoDictionary: infoDictionary,
            infoKey: "PostHogHost",
            fallback: Self.defaultPostHogHost
        )
    }

    private static func value(
        _ environment: [String: String],
        keys: [String],
        infoDictionary: [String: Any],
        infoKey: String
    ) -> String? {
        for key in keys {
            if let value = normalized(environment[key]) {
                return value
            }
        }

        return normalized(infoDictionary[infoKey] as? String)
    }

    private static func urlValue(
        _ environment: [String: String],
        keys: [String],
        infoDictionary: [String: Any],
        infoKey: String,
        fallback: URL
    ) -> URL {
        guard let value = value(
            environment,
            keys: keys,
            infoDictionary: infoDictionary,
            infoKey: infoKey
        ) else {
            return fallback
        }

        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil else {
            assertionFailure("Invalid URL for \(infoKey): \(value)")
            return fallback
        }

        return url
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
