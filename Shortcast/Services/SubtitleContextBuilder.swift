import Foundation

struct SubtitleTranslationContext: Sendable, Equatable {
    var targetLanguage: String
    var sourceLanguage: String
    var contentType: String
    var highlightTitle: String
    var highlightSummary: String
    var segmentTitle: String
    var contextBefore: String
    var contextAfter: String
    var speakerNotes: [String]
    var glossary: [String]
    var styleGuide: String
}

enum SubtitleContextBuilder {
    static func makeFullVideoContext(
        transcript: Transcript,
        targetLanguage: String,
        sourceLanguage: String?
    ) -> SubtitleTranslationContext {
        let text = transcript.segments.map(\.text).joined(separator: " ")
        let speakers = Array(Set(transcript.segments.compactMap(\.speakerID)))
            .sorted()
            .map { "\($0): speaker label supplied by the transcript; relationship, age, and gender are unknown unless stated in the text." }
        let detectedSourceLanguage = sourceLanguage?.trimmed ?? ""

        return SubtitleTranslationContext(
            targetLanguage: targetLanguage,
            sourceLanguage: detectedSourceLanguage.isEmpty ? "auto" : detectedSourceLanguage,
            contentType: "full educational video",
            highlightTitle: "",
            highlightSummary: "",
            segmentTitle: "",
            contextBefore: "",
            contextAfter: "",
            speakerNotes: speakers,
            glossary: glossaryCandidates(from: [text]),
            styleGuide: """
            Use clear, natural Vietnamese for subtitles. Prefer everyday Vietnamese when it preserves meaning; avoid stiff Sino-Vietnamese or literal calques. Keep technical terms precise and consistent.
            """)
    }

    static func makeContext(
        transcript: Transcript,
        plan: HighlightPlan,
        segment: HighlightSegment,
        targetLanguage: String,
        sourceLanguage: String?
    ) -> SubtitleTranslationContext {
        let selected = transcript.segments.filter { cue in
            cue.end > segment.start && cue.start < segment.end
        }
        let before = transcript.segments
            .filter { $0.end <= segment.start }
            .suffix(6)
            .map(contextLine)
            .joined(separator: " ")
        let after = transcript.segments
            .filter { $0.start >= segment.end }
            .prefix(6)
            .map(contextLine)
            .joined(separator: " ")
        let speakers = Array(Set(selected.compactMap(\.speakerID)))
            .sorted()
            .map { "\($0): speaker label supplied by the transcript; relationship, age, and gender are unknown unless stated in the text." }
        let glossary = glossaryCandidates(from: [
            plan.title,
            plan.summary,
            segment.title,
            selected.map(\.text).joined(separator: " "),
        ])
        let detectedSourceLanguage = sourceLanguage?.trimmed ?? ""

        return SubtitleTranslationContext(
            targetLanguage: targetLanguage,
            sourceLanguage: detectedSourceLanguage.isEmpty ? "auto" : detectedSourceLanguage,
            contentType: "educational highlight video",
            highlightTitle: plan.title.trimmed,
            highlightSummary: plan.summary.trimmed,
            segmentTitle: segment.title.trimmed,
            contextBefore: before,
            contextAfter: after,
            speakerNotes: speakers,
            glossary: glossary,
            styleGuide: """
            Use clear, natural Vietnamese for subtitles. Prefer everyday Vietnamese when it preserves meaning; avoid stiff Sino-Vietnamese or literal calques. Keep technical terms precise and consistent.
            """)
    }

    private static func contextLine(_ segment: TranscriptSegment) -> String {
        let text = SubtitleFormatter.inlineText(segment.text)
        guard !text.isEmpty else { return "" }
        if let speaker = segment.speakerID {
            return "\(speaker): \(text)"
        }
        return text
    }

    private static func glossaryCandidates(from fields: [String]) -> [String] {
        let text = fields.joined(separator: " ")
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z0-9.+#/-]{1,}\b"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var seen = Set<String>()
        var terms: [String] = []
        for match in matches {
            guard let termRange = Range(match.range, in: text) else { continue }
            let term = String(text[termRange]).trimmed
            guard isUsefulGlossaryTerm(term), seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count >= 12 { break }
        }
        return terms
    }

    private static func isUsefulGlossaryTerm(_ term: String) -> Bool {
        guard term.count >= 2 else { return false }
        if term.contains(where: { $0.isNumber }) { return true }
        if term.contains(where: { ".+#/-".contains($0) }) { return true }
        let letters = term.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return true }
        let chars = Array(term)
        return chars.dropFirst().contains(where: \.isUppercase)
    }
}
