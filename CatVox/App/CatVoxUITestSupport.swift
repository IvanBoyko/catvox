import Foundation
import SwiftData
import UIKit

enum CatVoxUITestSupport {
    private static let seededScanID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func resetPersistentState() {
        ScanQuotaStore.resetPersistedUsageForUITesting()
        UserIdentityStore.resetForUITesting()
        if let scansURL = try? scansRootDirectory() {
            try? FileManager.default.removeItem(at: scansURL)
        }
    }

    @MainActor
    static func seedIfNeeded(
        configuration: CatVoxLaunchConfiguration,
        modelContext: ModelContext
    ) {
        guard configuration.isUITesting, configuration.seedHistory else { return }

        let descriptor = FetchDescriptor<SavedScan>()
        if let existingScans = try? modelContext.fetch(descriptor), !existingScans.isEmpty {
            return
        }

        do {
            try createSeedFilesIfNeeded()
            modelContext.insert(makeSeededScan())
            try modelContext.save()
        } catch {
            assertionFailure("Failed to seed UI test history: \(error)")
        }
    }

    private static func makeSeededScan() -> SavedScan {
        let analysis = CatAnalysis(
            id: seededScanID,
            primaryEmotion: "Curious Focus",
            confidenceScore: 0.91,
            analysis: "The cat is alert, visually tracking nearby movement without signs of distress.",
            personaType: CatPersona.secretAgent.rawValue,
            catThought: "Mission parameters accepted. The hallway is under surveillance.",
            ownerTip: "Offer a short wand-toy session to reward that focused attention.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        return SavedScan(
            id: analysis.id,
            createdAt: analysis.timestamp,
            sourceType: .recorded,
            originalVideoRelativePath: "\(seededScanID.uuidString)/original.mov",
            thumbnailRelativePath: "\(seededScanID.uuidString)/thumbnail.jpg",
            primaryEmotion: analysis.primaryEmotion,
            confidenceScore: analysis.confidenceScore,
            analysisText: analysis.analysis,
            personaType: analysis.personaType,
            catThought: analysis.catThought,
            ownerTip: analysis.ownerTip
        )
    }

    private static func createSeedFilesIfNeeded() throws {
        let directory = try scansRootDirectory()
            .appendingPathComponent(seededScanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let videoURL = directory.appendingPathComponent("original.mov")
        if !FileManager.default.fileExists(atPath: videoURL.path) {
            try Data("CatVox UI test video placeholder".utf8).write(to: videoURL, options: .atomic)
        }

        let thumbnailURL = directory.appendingPathComponent("thumbnail.jpg")
        if !FileManager.default.fileExists(atPath: thumbnailURL.path) {
            try makeThumbnailData().write(to: thumbnailURL, options: .atomic)
        }
    }

    private static func makeThumbnailData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        let image = renderer.image { context in
            UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor(red: 0.25, green: 0.78, blue: 0.92, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 28, y: 28, width: 40, height: 40))
        }

        guard let data = image.jpegData(compressionQuality: 0.82) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func scansRootDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("Scans", isDirectory: true)
    }
}
