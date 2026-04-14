import Foundation

/// Static mock data for UI development and Xcode Previews.
/// Replace with live `AnalysisService` (Phase 2) when the Firebase
/// Cloud Function is wired up.
enum MockAnalysisService {

    static let sampleAnalysis = CatAnalysis(
        primaryEmotion:  "Territorial Alertness",
        confidenceScore: 0.87,
        analysis: """
            The subject displays classic signs of heightened territorial awareness. \
            Ear position is upright and forward-facing, indicating active sound processing. \
            Tail movement is slow and deliberate — a key marker of focused attention rather than aggression.
            """,
        personaType: CatPersona.grumpyBoss.rawValue,
        catThought: """
            I have reviewed the perimeter. The service entrance at the kitchen remains insufficiently \
            guarded. I expect a full briefing on the suspicious activity near my food bowl by 0800 hours. \
            Failure is not an option.
            """,
        ownerTip: """
            Your cat is on high alert — possibly reacting to outdoor sounds or movement. \
            Try closing the blinds and running a 5-minute wand-toy session to redirect that focus energy.
            """
    )

    static let allSamples: [CatAnalysis] = [
        sampleAnalysis,

        CatAnalysis(
            primaryEmotion:  "Existential Ennui",
            confidenceScore: 0.72,
            analysis: """
                The subject is in a state of deep contemplation, evidenced by slow blinking, \
                relaxed body posture, and minimal tail movement. The elongated gaze suggests \
                philosophical pondering rather than active prey drive.
                """,
            personaType: CatPersona.existentialPhilosopher.rawValue,
            catThought: """
                The kibble. It is always the kibble. But what IS the kibble, truly? A circle of \
                compressed matter, destined to be consumed, just as we are all consumed by the \
                indifferent passage of time. I hunger. But for what?
                """,
            ownerTip: """
                Your cat is deeply relaxed and content. Slow-blink back at them — it reinforces \
                your bond and signals safety.
                """
        ),

        CatAnalysis(
            primaryEmotion:  "Maximum Zoomies",
            confidenceScore: 0.95,
            analysis: """
                The subject is exhibiting classic frenetic random activity periods (FRAPs). Dilated \
                pupils, rapid directional changes, and explosive bursts of speed indicate a full \
                discharge of pent-up predatory energy.
                """,
            personaType: CatPersona.chaoticHunter.rawValue,
            catThought: """
                THERE IS NO TIME. THE INVISIBLE PREY IS EVERYWHERE. LEFT FLANK — SECURED. \
                RIGHT FLANK — COMPROMISED. THE CORNER OF THE RUG IS THE ENEMY. \
                I WILL DESTROY IT AT MACH 4. NONE SHALL PASS.
                """,
            ownerTip: """
                FRAPs are completely normal and healthy! Clear the space of hazards. \
                After the burst ends, offer a small treat to signal the "hunt" is complete.
                """
        ),
    ]
}
