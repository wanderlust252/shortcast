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
    var title: String
    var summary: String
    var segments: [HighlightSegment]

    var duration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    func outputRangeLabel(for segment: HighlightSegment) -> String {
        var cursor = 0.0
        for item in segments {
            if item.id == segment.id {
                return HighlightSegment.label(cursor) + "-" + HighlightSegment.label(cursor + item.duration)
            }
            cursor += item.duration
        }
        return ""
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
