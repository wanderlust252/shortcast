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
                let text = SubtitleFormatter.displayText(cue.text)
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

struct TranslatedVideo: Sendable, Equatable {
    var url: URL
    var renderedTranscript: Transcript
    var durationSeconds: Double
    var aspectMode: HighlightAspectMode

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

    func renderedSRT() -> String? {
        let entries = renderedTranscript.segments.compactMap { segment -> (start: Double, end: Double, text: String)? in
            let text = SubtitleFormatter.displayText(segment.text)
            guard !text.isEmpty, segment.end - segment.start >= 0.2 else { return nil }
            return (segment.start, segment.end, text)
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

struct ReviewRenderOutput: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case highlight
        case translatedFullVideo
        case translatedShort

        var displayName: String {
            switch self {
            case .highlight: "Highlight"
            case .translatedFullVideo: "Full subtitled video"
            case .translatedShort: "Subtitled short"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var url: URL
    var title: String
    var createdAt: Date = Date()
    var durationSeconds: Double
    var aspectMode: HighlightAspectMode
    var renderedTranscript: Transcript

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

enum SubtitleReviewMode: Sendable, Equatable {
    case highlight
    case fullVideo

    var displayName: String {
        switch self {
        case .highlight: "Highlight subtitles"
        case .fullVideo: "Full-video subtitles"
        }
    }
}

struct PendingSubtitleReview: Sendable, Equatable {
    var mode: SubtitleReviewMode
    var sourceURL: URL
    var sourceFileName: String
    var sourceDurationSeconds: Double
    var plan: HighlightPlan?
    var sourceTranscript: Transcript
    var renderedTranscript: Transcript
    var aspectMode: HighlightAspectMode
    var showIntroCard: Bool
    var exportQuality: ExportQualityMode
    var excludedCueIndices: Set<Int> = []

    var cueCount: Int { includedReviewIndices.count }
    var totalCueCount: Int { reviewIndices.count }
    var excludedCueCount: Int { excludedCueIndices.count }

    var reviewIndices: [Int] {
        switch mode {
        case .fullVideo:
            return Array(renderedTranscript.segments.indices)
        case .highlight:
            guard let plan else { return [] }
            return renderedTranscript.segments.indices.filter { index in
                let cue = renderedTranscript.segments[index]
                return plan.segments.contains { segment in
                    cue.end > segment.start && cue.start < segment.end
                }
            }
        }
    }

    var includedReviewIndices: [Int] {
        reviewIndices.filter { !excludedCueIndices.contains($0) }
    }

    var hasCustomSelection: Bool {
        !excludedCueIndices.isEmpty
    }

    func sourceSegment(at index: Int) -> TranscriptSegment? {
        guard sourceTranscript.segments.indices.contains(index) else { return nil }
        return sourceTranscript.segments[index]
    }

    mutating func updateRenderedText(at index: Int, text: String) {
        guard renderedTranscript.segments.indices.contains(index) else { return }
        var segments = renderedTranscript.segments
        let segment = segments[index]
        segments[index] = TranscriptSegment(
            start: segment.start,
            end: segment.end,
            text: SubtitleFormatter.inlineText(text),
            speakerID: segment.speakerID)
        renderedTranscript = Transcript(segments: segments, language: renderedTranscript.language)
    }

    mutating func setCueIncluded(at index: Int, included: Bool) {
        guard reviewIndices.contains(index) else { return }
        if included {
            excludedCueIndices.remove(index)
        } else {
            excludedCueIndices.insert(index)
        }
    }

    mutating func restoreAllCues() {
        excludedCueIndices.removeAll()
    }

    mutating func deselectAllCues() {
        excludedCueIndices = Set(reviewIndices)
    }

    func filteredRenderedTranscript() -> Transcript {
        let segments = includedReviewIndices.compactMap { index in
            renderedTranscript.segments.indices.contains(index) ? renderedTranscript.segments[index] : nil
        }
        return Transcript(segments: segments, language: renderedTranscript.language)
    }

    func filteredSourceTranscript() -> Transcript {
        let segments = includedReviewIndices.compactMap { index in
            sourceTranscript.segments.indices.contains(index) ? sourceTranscript.segments[index] : nil
        }
        return Transcript(segments: segments, language: sourceTranscript.language)
    }

    func selectionPlan(title: String? = nil) -> HighlightPlan? {
        let cues = includedReviewIndices.compactMap { index in
            renderedTranscript.segments.indices.contains(index) ? renderedTranscript.segments[index] : nil
        }
        guard !cues.isEmpty else { return nil }

        var ranges: [(start: Double, end: Double)] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            guard cue.end - cue.start >= 0.2 else { continue }
            if let last = ranges.last, cue.start - last.end <= 1.0 {
                ranges[ranges.count - 1].end = max(last.end, cue.end)
            } else {
                ranges.append((cue.start, cue.end))
            }
        }
        guard !ranges.isEmpty else { return nil }

        let segments = ranges.enumerated().map { offset, range in
            HighlightSegment(
                start: max(0, range.start),
                end: max(range.start + 0.2, range.end),
                title: "Selected segment \(offset + 1)",
                why: "")
        }
        return HighlightPlan(
            title: title ?? sourceFileName.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression),
            summary: "\(segments.count) selected segment\(segments.count == 1 ? "" : "s") from subtitle review.",
            segments: segments)
    }

    func renderedSRT() -> String? {
        switch mode {
        case .highlight:
            return highlightSRT()
        case .fullVideo:
            return fullVideoSRT()
        }
    }

    private func highlightSRT() -> String? {
        guard let plan else { return nil }
        var entries: [(start: Double, end: Double, text: String)] = []
        var cursor = showIntroCard ? HighlightPlan.introDuration : 0
        for segment in plan.segments {
            for index in includedReviewIndices {
                guard renderedTranscript.segments.indices.contains(index) else { continue }
                let cue = renderedTranscript.segments[index]
                guard cue.end > segment.start && cue.start < segment.end else { continue }
                let sourceStart = max(cue.start, segment.start)
                let sourceEnd = min(cue.end, segment.end)
                guard sourceEnd - sourceStart >= 0.2 else { continue }
                let text = SubtitleFormatter.displayText(cue.text)
                guard !text.isEmpty else { continue }
                entries.append((
                    start: cursor + (sourceStart - segment.start),
                    end: cursor + (sourceEnd - segment.start),
                    text: text))
            }
            cursor += segment.duration
        }
        return Self.srt(entries)
    }

    private func fullVideoSRT() -> String? {
        if hasCustomSelection, let plan = selectionPlan() {
            var entries: [(start: Double, end: Double, text: String)] = []
            var cursor = 0.0
            for segment in plan.segments {
                for index in includedReviewIndices {
                    guard renderedTranscript.segments.indices.contains(index) else { continue }
                    let cue = renderedTranscript.segments[index]
                    guard cue.end > segment.start && cue.start < segment.end else { continue }
                    let sourceStart = max(cue.start, segment.start)
                    let sourceEnd = min(cue.end, segment.end)
                    guard sourceEnd - sourceStart >= 0.2 else { continue }
                    let text = SubtitleFormatter.displayText(cue.text)
                    guard !text.isEmpty else { continue }
                    entries.append((
                        start: cursor + (sourceStart - segment.start),
                        end: cursor + (sourceEnd - segment.start),
                        text: text))
                }
                cursor += segment.duration
            }
            return Self.srt(entries)
        }

        let entries = includedReviewIndices.compactMap { index -> (start: Double, end: Double, text: String)? in
            guard renderedTranscript.segments.indices.contains(index) else { return nil }
            let segment = renderedTranscript.segments[index]
            let text = SubtitleFormatter.displayText(segment.text)
            guard !text.isEmpty, segment.end - segment.start >= 0.2 else { return nil }
            return (segment.start, segment.end, text)
        }
        return Self.srt(entries)
    }

    private static func srt(_ entries: [(start: Double, end: Double, text: String)]) -> String? {
        guard !entries.isEmpty else { return nil }
        return entries.enumerated().map { index, entry in
            """
            \(index + 1)
            \(srtTimestamp(entry.start)) --> \(srtTimestamp(entry.end))
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

enum ExportQualityMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case smallerFile
    case balanced
    case highestQuality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .smallerFile: "Smaller file"
        case .balanced: "Balanced"
        case .highestQuality: "Highest quality"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Chooses a sensible bitrate from the output size and source bitrate."
        case .smallerFile:
            "Keeps exports compact; best for lectures, slides, and sharing."
        case .balanced:
            "Uses a moderate bitrate for cleaner motion and readable subtitles."
        case .highestQuality:
            "Lets AVFoundation preserve maximum quality; files can become very large."
        }
    }
}
