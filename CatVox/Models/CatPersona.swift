import SwiftUI

/// The six AI-assigned personality archetypes defined in Instructions.md §3.
/// Each case drives the accent colour, emoji, and tone of the Result screen.
enum CatPersona: String, CaseIterable, Hashable {
    case grumpyBoss             = "The Grumpy Boss"
    case existentialPhilosopher = "The Existential Philosopher"
    case chaoticHunter          = "The Chaotic Hunter"
    case dramaticDiva           = "The Dramatic Diva"
    case affectionateSweetheart = "The Affectionate Sweetheart"
    case secretAgent            = "The Secret Agent"

    // MARK: - Visual Identity

    var emoji: String {
        switch self {
        case .grumpyBoss:             return "😤"
        case .existentialPhilosopher: return "🤔"
        case .chaoticHunter:          return "🏹"
        case .dramaticDiva:           return "💅"
        case .affectionateSweetheart: return "🥰"
        case .secretAgent:            return "🕵️"
        }
    }

    var accentColor: Color {
        switch self {
        case .grumpyBoss:             return Color(red: 0.90, green: 0.22, blue: 0.22)
        case .existentialPhilosopher: return Color(red: 0.60, green: 0.30, blue: 0.90)
        case .chaoticHunter:          return Color(red: 1.00, green: 0.50, blue: 0.10)
        case .dramaticDiva:           return Color(red: 0.90, green: 0.28, blue: 0.68)
        case .affectionateSweetheart: return Color(red: 0.25, green: 0.85, blue: 0.68)
        case .secretAgent:            return Color(red: 0.18, green: 0.78, blue: 0.92)
        }
    }

    // MARK: - Display

    /// Short spaced-hyphen label used in UI chips and badges.
    /// Keeps `rawValue` intact for API round-tripping.
    var displayName: String {
        switch self {
        case .grumpyBoss:             return "Grumpy Boss"
        case .existentialPhilosopher: return "Existential Philosopher"
        case .chaoticHunter:          return "Chaotic Hunter"
        case .dramaticDiva:           return "Dramatic Diva"
        case .affectionateSweetheart: return "Affectionate Sweetheart"
        case .secretAgent:            return "Secret Agent"
        }
    }

    // MARK: - Helpers

    /// Fallback to `.grumpyBoss` if the AI returns an unrecognised string.
    static func from(_ rawValue: String) -> CatPersona {
        CatPersona(rawValue: rawValue) ?? .grumpyBoss
    }
}
