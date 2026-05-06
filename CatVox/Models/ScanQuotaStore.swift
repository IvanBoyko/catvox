import Foundation
import Observation

/// Client-side mirror of the server's daily scan quota.
///
/// The server remains the enforcement authority (returns HTTP 429 when the
/// limit is reached). This store tracks usage locally so the home screen
/// can show a live countdown without a round-trip. It resets at midnight,
/// matching the server's `lastResetDate` logic in usageGuard.ts.
@MainActor
@Observable
final class ScanQuotaStore {

    static let dailyLimit = 5

    private(set) var scansRemaining: Int

    init(initialScansRemaining: Int? = nil) {
        scansRemaining = initialScansRemaining ?? Self.compute()
    }

    /// Call after a successful analysis completes.
    func recordScan() {
        resetIfNewDay()
        let used = min(UserDefaults.standard.integer(forKey: Keys.used) + 1, Self.dailyLimit)
        persist(used: used)
        scansRemaining = max(0, Self.dailyLimit - used)
    }

    /// Call when the server returns HTTP 429 — sync to the hard limit.
    func markExhausted() {
        persist(used: Self.dailyLimit)
        scansRemaining = 0
    }

    // MARK: - Private

    private enum Keys {
        static let used     = "catvox.scansUsedToday"
        static let lastDate = "catvox.lastScanDate"
    }

    nonisolated static func resetPersistedUsageForUITesting() {
        UserDefaults.standard.removeObject(forKey: Keys.used)
        UserDefaults.standard.removeObject(forKey: Keys.lastDate)
    }

    private static func compute() -> Int {
        guard storedDate() == today else { return dailyLimit }
        return max(0, dailyLimit - UserDefaults.standard.integer(forKey: Keys.used))
    }

    private func resetIfNewDay() {
        if Self.storedDate() != Self.today {
            UserDefaults.standard.set(0, forKey: Keys.used)
        }
    }

    private func persist(used: Int) {
        UserDefaults.standard.set(used,      forKey: Keys.used)
        UserDefaults.standard.set(Self.today, forKey: Keys.lastDate)
    }

    private static func storedDate() -> String {
        UserDefaults.standard.string(forKey: Keys.lastDate) ?? ""
    }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
