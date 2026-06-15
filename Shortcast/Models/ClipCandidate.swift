import Foundation

/// One useful moment picked out of a long video's transcript: a time range plus
/// why it belongs in the edit and a suggested on-screen title.
struct ClipCandidate: Sendable, Identifiable, Equatable {
    let id = UUID()
    /// Start offset in seconds.
    var start: Double
    /// End offset in seconds.
    var end: Double
    /// Editorial rationale for why this segment belongs in the edit.
    var why: String
    /// Suggested plain-language title.
    var hook: String
    /// Short on-screen text (a few words) for the burned-in overlay.
    var overlay: String = ""

    /// Legacy three-card text package, when the helper writes it inline in the
    /// same pass. Empty when summaries are produced separately.
    var variants: [PostVariant] = []

    var duration: Double { end - start }

    /// `m:ss–m:ss`, e.g. `0:51–1:09`.
    var rangeLabel: String {
        Self.label(start) + "–" + Self.label(end)
    }

    private static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
