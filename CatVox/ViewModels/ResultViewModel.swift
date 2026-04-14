import SwiftUI
import Observation

@Observable
final class ResultViewModel {

    // MARK: - State

    let analysis: CatAnalysis
    var isInsightsExpanded: Bool  = false
    var thoughtBubbleVisible: Bool = false
    var panelVisible: Bool         = false

    // MARK: - Derived

    var persona: CatPersona {
        CatPersona.from(analysis.personaType)
    }

    var shareText: String {
        """
        My cat just spoke... \(persona.emoji)

        "\(analysis.catThought)"

        Mood: \(analysis.primaryEmotion)

        Decoded by CatVox AI – Powered by Kathelix.com
        """
    }

    // MARK: - Init

    init(analysis: CatAnalysis) {
        self.analysis = analysis
    }

    // MARK: - Lifecycle

    func onAppear() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72).delay(0.35)) {
            panelVisible = true
        }
        withAnimation(.spring(response: 0.65, dampingFraction: 0.68).delay(0.65)) {
            thoughtBubbleVisible = true
        }
    }
}
