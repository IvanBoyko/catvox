import Foundation

enum UserIdentityStore {
    private static let key = "catvox.userId"

    static var userID: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static func resetForUITesting() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
