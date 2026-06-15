import Foundation

/// A short video the user dropped onto the window, plus the metadata Shortcast
/// needs to process and publish it.
struct VideoJob: Identifiable, Sendable, Equatable {
    let id = UUID()
    let url: URL
    let durationSeconds: Double

    var fileName: String { url.lastPathComponent }

    /// `m:ss`, e.g. `0:42`.
    var durationLabel: String {
        let total = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The legacy single-clip helper is tuned for ~60s inputs. Longer videos
    /// still work, but the audio tower only hears the first 30s.
    var exceedsRecommendedLength: Bool { durationSeconds > 60.5 }
}
