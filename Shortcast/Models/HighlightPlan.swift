import Foundation

struct HighlightSegment: Sendable, Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var title: String
    var why: String

    var duration: Double { end - start }

    var rangeLabel: String {
        Self.label(start) + "-" + Self.label(end)
    }

    static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct HighlightPlan: Sendable, Equatable {
    static let introDuration = 3.0
    static let transitionDuration = 0.4

    var title: String
    var summary: String
    var segments: [HighlightSegment]

    var duration: Double {
        Self.renderedDuration(for: segments)
    }

    func outputRangeLabel(for segment: HighlightSegment) -> String {
        var cursor = Self.introDuration
        for item in segments {
            if item.id == segment.id {
                return HighlightSegment.label(cursor) + "-" + HighlightSegment.label(cursor + item.duration)
            }
            cursor += item.duration
        }
        return ""
    }

    static func renderedDuration(for segments: [HighlightSegment]) -> Double {
        guard !segments.isEmpty else { return 0 }
        let content = segments.reduce(0) { $0 + $1.duration }
        return introDuration + content
    }
}

struct HighlightVideo: Sendable, Equatable {
    var plan: HighlightPlan
    var url: URL
    var aspectMode: HighlightAspectMode
    var durationSeconds: Double

    var durationLabel: String {
        let total = Int(durationSeconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

enum HighlightAspectMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case vertical
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vertical: "Vertical 9:16"
        case .original: "Original ratio"
        }
    }
}
