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
    var showIntroCard: Bool = true
    var sourceTranscript: Transcript? = nil
    var renderedTranscript: Transcript? = nil
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

    func outputRangeLabel(for segment: HighlightSegment) -> String {
        var cursor = showIntroCard ? HighlightPlan.introDuration : 0
        for item in plan.segments {
            if item.id == segment.id {
                return HighlightSegment.label(cursor) + "-" + HighlightSegment.label(cursor + item.duration)
            }
            cursor += item.duration
        }
        return ""
    }

    func subtitleSRT(kind: SubtitleExportKind) -> String? {
        let transcript: Transcript?
        switch kind {
        case .source:
            transcript = sourceTranscript
        case .rendered:
            transcript = renderedTranscript ?? sourceTranscript
        }
        guard let transcript else { return nil }

        var entries: [(start: Double, end: Double, text: String)] = []
        var cursor = showIntroCard ? HighlightPlan.introDuration : 0
        for segment in plan.segments {
            for cue in transcript.segments where cue.end > segment.start && cue.start < segment.end {
                let sourceStart = max(cue.start, segment.start)
                let sourceEnd = min(cue.end, segment.end)
                guard sourceEnd - sourceStart >= 0.2 else { continue }
                let text = TranscriptionService.cleanTranscriptText(cue.text)
                guard !text.isEmpty else { continue }
                entries.append((
                    start: cursor + (sourceStart - segment.start),
                    end: cursor + (sourceEnd - segment.start),
                    text: text))
            }
            cursor += segment.duration
        }
        guard !entries.isEmpty else { return nil }

        return entries.enumerated().map { index, entry in
            """
            \(index + 1)
            \(Self.srtTimestamp(entry.start)) --> \(Self.srtTimestamp(entry.end))
            \(entry.text)
            """
        }
        .joined(separator: "\n\n")
        + "\n"
    }

    private static func srtTimestamp(_ seconds: Double) -> String {
        let msTotal = Int((max(0, seconds) * 1000).rounded())
        let hours = msTotal / 3_600_000
        let minutes = (msTotal % 3_600_000) / 60_000
        let secs = (msTotal % 60_000) / 1000
        let millis = msTotal % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}

enum SubtitleExportKind {
    case source
    case rendered
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
