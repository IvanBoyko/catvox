import Foundation

/// Mirrors the JSON schema returned by the Firebase/Vertex AI backend.
/// See TRD §4.2 and Instructions.md §4 for the full response schema.
struct CatAnalysis: Codable, Identifiable, Hashable {
    let id: UUID
    let primaryEmotion: String
    let confidenceScore: Double
    let analysis: String
    let personaType: String
    let catThought: String
    let ownerTip: String
    let timestamp: Date

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case primaryEmotion  = "primary_emotion"
        case confidenceScore = "confidence_score"
        case analysis
        case personaType     = "persona_type"
        case catThought      = "cat_thought"
        case ownerTip        = "owner_tip"
    }

    /// Memberwise init (used by mock data & SwiftData reconstruction).
    init(
        id: UUID = UUID(),
        primaryEmotion: String,
        confidenceScore: Double,
        analysis: String,
        personaType: String,
        catThought: String,
        ownerTip: String,
        timestamp: Date = Date()
    ) {
        self.id              = id
        self.primaryEmotion  = primaryEmotion
        self.confidenceScore = confidenceScore
        self.analysis        = analysis
        self.personaType     = personaType
        self.catThought      = catThought
        self.ownerTip        = ownerTip
        self.timestamp       = timestamp
    }

    /// Decoding init — injects a fresh UUID and current timestamp
    /// since the backend omits those fields.
    init(from decoder: Decoder) throws {
        let c            = try decoder.container(keyedBy: CodingKeys.self)
        id               = UUID()
        primaryEmotion   = try c.decode(String.self,  forKey: .primaryEmotion)
        confidenceScore  = try c.decode(Double.self,  forKey: .confidenceScore)
        analysis         = try c.decode(String.self,  forKey: .analysis)
        personaType      = try c.decode(String.self,  forKey: .personaType)
        catThought       = try c.decode(String.self,  forKey: .catThought)
        ownerTip         = try c.decode(String.self,  forKey: .ownerTip)
        timestamp        = Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(primaryEmotion,  forKey: .primaryEmotion)
        try c.encode(confidenceScore, forKey: .confidenceScore)
        try c.encode(analysis,        forKey: .analysis)
        try c.encode(personaType,     forKey: .personaType)
        try c.encode(catThought,      forKey: .catThought)
        try c.encode(ownerTip,        forKey: .ownerTip)
    }
}
