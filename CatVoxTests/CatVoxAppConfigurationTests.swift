import XCTest
@testable import CatVox

final class CatVoxAppConfigurationTests: XCTestCase {
    func testUsesPreSplitDefaultsWhenConfigurationIsMissing() {
        let configuration = CatVoxAppConfiguration(
            infoDictionary: [:],
            environment: [:]
        )

        XCTAssertEqual(configuration.environmentName, "dev")
        XCTAssertEqual(
            configuration.signedUploadURLEndpoint,
            URL(string: "https://getsigneduploadurl-pdkw5uifga-uc.a.run.app")!
        )
        XCTAssertEqual(
            configuration.analyseVideoEndpoint,
            URL(string: "https://analysevideo-pdkw5uifga-uc.a.run.app")!
        )
        XCTAssertNil(configuration.postHogProjectToken)
        XCTAssertEqual(configuration.postHogHost, URL(string: "https://us.i.posthog.com")!)
    }

    func testReadsEnvironmentConfigurationFromInfoDictionary() {
        let configuration = CatVoxAppConfiguration(
            infoDictionary: [
                "CatVoxEnvironment": "staging",
                "CatVoxSignedUploadURLEndpoint": "https://signed.example.com",
                "CatVoxAnalyseVideoEndpoint": "https://analyse.example.com",
                "CatVoxPostHogProjectToken": "posthog-token",
                "CatVoxPostHogHost": "https://eu.i.posthog.com",
            ],
            environment: [:]
        )

        XCTAssertEqual(configuration.environmentName, "staging")
        XCTAssertEqual(configuration.signedUploadURLEndpoint, URL(string: "https://signed.example.com")!)
        XCTAssertEqual(configuration.analyseVideoEndpoint, URL(string: "https://analyse.example.com")!)
        XCTAssertEqual(configuration.postHogProjectToken, "posthog-token")
        XCTAssertEqual(configuration.postHogHost, URL(string: "https://eu.i.posthog.com")!)
    }

    func testEnvironmentVariablesOverrideInfoDictionaryValues() {
        let configuration = CatVoxAppConfiguration(
            infoDictionary: [
                "CatVoxEnvironment": "prod",
                "CatVoxSignedUploadURLEndpoint": "https://signed-prod.example.com",
                "CatVoxAnalyseVideoEndpoint": "https://analyse-prod.example.com",
                "CatVoxPostHogProjectToken": "posthog-prod",
                "CatVoxPostHogHost": "https://prod.posthog.example.com",
            ],
            environment: [
                "CATVOX_ENVIRONMENT": "qa",
                "CATVOX_SIGNED_UPLOAD_URL_ENDPOINT": "https://signed-qa.example.com",
                "CATVOX_ANALYSE_VIDEO_ENDPOINT": "https://analyse-qa.example.com",
                "CATVOX_POSTHOG_PROJECT_TOKEN": "posthog-qa",
                "CATVOX_POSTHOG_HOST": "https://qa.posthog.example.com",
            ]
        )

        XCTAssertEqual(configuration.environmentName, "qa")
        XCTAssertEqual(configuration.signedUploadURLEndpoint, URL(string: "https://signed-qa.example.com")!)
        XCTAssertEqual(configuration.analyseVideoEndpoint, URL(string: "https://analyse-qa.example.com")!)
        XCTAssertEqual(configuration.postHogProjectToken, "posthog-qa")
        XCTAssertEqual(configuration.postHogHost, URL(string: "https://qa.posthog.example.com")!)
    }

    func testBuildSettingPlaceholdersAreTreatedAsMissing() {
        let configuration = CatVoxAppConfiguration(
            infoDictionary: [
                "CatVoxEnvironment": "$(CATVOX_ENVIRONMENT)",
                "PostHogProjectToken": "$(CATVOX_POSTHOG_PROJECT_TOKEN)",
            ],
            environment: [:]
        )

        XCTAssertEqual(configuration.environmentName, "dev")
        XCTAssertNil(configuration.postHogProjectToken)
    }

    func testReleaseStyleRuntimeConfigurationRejectsMissingRequiredValues() {
        XCTAssertThrowsError(
            try CatVoxAppConfiguration(
                infoDictionary: [:],
                environment: [:],
                allowDebugDefaults: false
            )
        )
    }

    func testReleaseStyleRuntimeConfigurationRejectsInvalidURLs() {
        XCTAssertThrowsError(
            try CatVoxAppConfiguration(
                infoDictionary: [
                    "CatVoxEnvironment": "prod",
                    "CatVoxSignedUploadURLEndpoint": "not-a-url",
                    "CatVoxAnalyseVideoEndpoint": "https://analyse.example.com",
                    "CatVoxPostHogHost": "https://us.i.posthog.com",
                ],
                environment: [:],
                allowDebugDefaults: false
            )
        )
    }

    func testLegacyPostHogInfoKeysRemainSupportedDuringTransition() throws {
        let configuration = try CatVoxAppConfiguration(
            infoDictionary: [
                "CatVoxEnvironment": "staging",
                "CatVoxSignedUploadURLEndpoint": "https://signed.example.com",
                "CatVoxAnalyseVideoEndpoint": "https://analyse.example.com",
                "PostHogProjectToken": "legacy-token",
                "PostHogHost": "https://legacy.posthog.example.com",
            ],
            environment: [:],
            allowDebugDefaults: false
        )

        XCTAssertEqual(configuration.postHogProjectToken, "legacy-token")
        XCTAssertEqual(configuration.postHogHost, URL(string: "https://legacy.posthog.example.com")!)
    }
}
