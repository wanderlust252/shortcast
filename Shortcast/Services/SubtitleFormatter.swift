import Foundation

enum SubtitleFormatter {
    static let targetCharactersPerLine = 40
    static let maxLines = 2

    static func clean(_ raw: String) -> String {
        var text = TranscriptionService.cleanTranscriptText(raw)
        let timecode = #"\d{1,2}:\d{2}(?::\d{2})?(?:[,.]\d{1,3})?"#
        let patterns = [
            #"(?:\(|\[)?"# + timecode + #"\s*(?:-->|-|–|—|to)\s*"# + timecode + #"(?:\)|\])?"#,
            #"^\s*(?:[\[(]?"# + timecode + #"[\])]?\s*)+"#,
            #"(?:\s*[\[(]?"# + timecode + #"[\])]?\s*)+$"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmed
    }

    static func inlineText(_ raw: String) -> String {
        clean(raw)
    }

    static func displayText(
        _ raw: String,
        charactersPerLine: Int = targetCharactersPerLine,
        maxLines: Int = maxLines
    ) -> String {
        let text = clean(raw)
        guard !text.isEmpty else { return "" }
        return wrappedLines(
            text,
            charactersPerLine: max(12, charactersPerLine),
            maxLines: max(1, maxLines))
            .joined(separator: "\n")
    }

    static func needsRepair(
        _ raw: String,
        charactersPerLine: Int = targetCharactersPerLine,
        maxLines: Int = maxLines
    ) -> Bool {
        let text = clean(raw)
        guard !text.isEmpty else { return true }
        let lines = wrappedLines(
            text,
            charactersPerLine: max(12, charactersPerLine),
            maxLines: max(1, maxLines))
        return lines.contains { $0.count > charactersPerLine }
    }

    private static func wrappedLines(
        _ text: String,
        charactersPerLine: Int,
        maxLines: Int
    ) -> [String] {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""
        for token in tokens.flatMap({ splitLongToken($0, charactersPerLine: charactersPerLine) }) {
            if current.isEmpty {
                current = token
            } else if current.count + 1 + token.count <= charactersPerLine {
                current += " " + token
            } else {
                lines.append(current)
                current = token
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }

        guard lines.count > maxLines else { return lines }
        let head = lines.prefix(max(0, maxLines - 1))
        let tail = lines.dropFirst(max(0, maxLines - 1)).joined(separator: " ")
        return Array(head) + [tail]
    }

    private static func splitLongToken(_ token: String, charactersPerLine: Int) -> [String] {
        guard token.count > charactersPerLine else { return [token] }
        var chunks: [String] = []
        var cursor = token.startIndex
        while cursor < token.endIndex {
            let end = token.index(cursor, offsetBy: charactersPerLine, limitedBy: token.endIndex) ?? token.endIndex
            chunks.append(String(token[cursor..<end]))
            cursor = end
        }
        return chunks
    }
}
