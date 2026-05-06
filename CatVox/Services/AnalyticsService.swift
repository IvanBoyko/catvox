import Foundation
import os
import PostHog

enum AnalyticsService {
    enum Event: String {
        case analysisCompleted = "analysis_completed"
        case analysisFailed = "analysis_failed"
        case analysisRetryTapped = "analysis_retry_tapped"
        case photosClipSelected = "photos_clip_selected"
        case photosPermissionDenied = "photos_permission_denied"
        case photosPickerCancelled = "photos_picker_cancelled"
        case photosPickerOpened = "photos_picker_opened"
        case quotaCardShown = "quota_card_shown"
        case quotaExceeded = "quota_exceeded"
        case recordingCancelled = "recording_cancelled"
        case recordingCompleted = "recording_completed"
        case recordingFinished = "recording_finished"
        case recordingRetakeTapped = "recording_retake_tapped"
        case recordingStarted = "recording_started"
        case scanDeleted = "scan_deleted"
        case scanSavedToPhotos = "scan_saved_to_photos"
        case scanShared = "scan_shared"
        case scanSourceChosen = "scan_source_chosen"
        case shareExportRenderFailed = "share_export_render_failed"
        case shareExportStarted = "share_export_started"
        case shareSaveFailed = "share_save_failed"
        case shareSheetCancelled = "share_sheet_cancelled"
        case shareSheetOpened = "share_sheet_opened"
        case upgradeToProTapped = "upgrade_to_pro_tapped"
        case videoValidationFailed = "video_validation_failed"
        case videoValidationPassed = "video_validation_passed"
    }

    private static let logger = Logger(subsystem: "com.kathelix.catvox", category: "Analytics")
    private static var isConfigured = false

    static func configure() {
        guard !isConfigured else { return }
        guard !isRuntimeDisabled else {
            logger.notice("PostHog disabled for test/preview runtime")
            return
        }
        guard let configuration = PostHogConfiguration.current else {
            logger.notice("PostHog disabled: missing project token")
            return
        }

        let config = PostHogConfig(
            projectToken: configuration.projectToken,
            host: configuration.host
        )
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.rageClickConfig.enabled = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.setDefaultPersonProperties = false
        config.sessionReplay = false
        config.surveys = false
        config.errorTrackingConfig.autoCapture = false

        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(
            UserIdentityStore.userID,
            userPropertiesSetOnce: ["catvox_install_id": UserIdentityStore.userID]
        )

        isConfigured = true
    }

    static func capture(_ event: Event, properties: [String: Any] = [:]) {
        guard isConfigured else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    private static var isRuntimeDisabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["CATVOX_DISABLE_ANALYTICS"] == "1" ||
            CatVoxLaunchConfiguration.current.isUITesting ||
            environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

private struct PostHogConfiguration {
    let projectToken: String
    let host: String

    static var current: PostHogConfiguration? {
        guard let projectToken = value(
            environmentKey: "POSTHOG_PROJECT_TOKEN",
            infoKey: "PostHogProjectToken"
        ) else {
            return nil
        }

        let host = value(
            environmentKey: "POSTHOG_HOST",
            infoKey: "PostHogHost"
        ) ?? "https://us.i.posthog.com"

        return PostHogConfiguration(projectToken: projectToken, host: host)
    }

    private static func value(environmentKey: String, infoKey: String) -> String? {
        if let environmentValue = normalized(ProcessInfo.processInfo.environment[environmentKey]) {
            return environmentValue
        }

        return normalized(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
