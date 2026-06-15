import Foundation

enum MimoError: LocalizedError {
    case notConfigured
    case invalidURL
    case noContent
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Xiaomi MiMo API key in Settings first."
        case .invalidURL:
            return "The MiMo API URL is invalid."
        case .noContent:
            return "MiMo did not return any text content."
        case .http(let status, let body):
            return "MiMo returned HTTP \(status). \(body)"
        }
    }
}

struct MimoService: Sendable {
    let apiKey: String
    let modelID: String
    let baseURL: String

    init(apiKey: String, modelID: String, baseURL: String = "") {
        self.apiKey = apiKey
        self.modelID = modelID
        self.baseURL = baseURL
    }

    private static let payAsYouGoBaseURL = URL(string: "https://api.xiaomimimo.com/v1")!
    private static let defaultTokenPlanBaseURL = URL(string: "https://token-plan-sgp.xiaomimimo.com/v1")!

    func findMoments(
        transcript: String,
        language: String?,
        styleExamples: String
    ) async throws -> [ClipCandidate] {
        let raw = try await complete(
            system: MomentFinderService.captioningPrompt(
                language: language,
                styleExamples: styleExamples),
            user: "Video transcript with timestamps:\n\n\(transcript)\n\nReturn the educational clips JSON.",
            maxTokens: 8192,
            temperature: 0.7,
            topP: 0.95)
        let clips = MomentJSONParser.parse(raw)
        guard !clips.isEmpty else { throw MomentFinderError.noClips }
        return clips
    }

    func planHighlight(
        transcript: String,
        language: String?,
        sourceDuration: Double
    ) async throws -> HighlightPlan {
        let raw = try await complete(
            system: Self.highlightSystemPrompt(language: language),
            user: """
            Source duration: \(Int(sourceDuration.rounded())) seconds

            Timestamped transcript:

            \(transcript)

            Return the highlight plan JSON.
            """,
            maxTokens: 8192,
            temperature: 0.35,
            topP: 0.9)
        let plan = HighlightPlanJSONParser.parse(raw, sourceDuration: sourceDuration)
        guard !plan.segments.isEmpty else { throw MomentFinderError.noClips }
        return plan
    }

    func caption(
        transcriptSlice: String,
        hook: String,
        languageOverride: String,
        styleExamples: String
    ) async throws -> GenerationResult {
        let raw = try await complete(
            system: PromptBuilder.buildTranscriptPrompt(
                languageOverride: languageOverride,
                styleExamples: styleExamples),
            user: "Suggested hook: \(hook)\n\nClip transcript:\n\(transcriptSlice)\n\nReturn the JSON package.",
            maxTokens: 2048,
            temperature: 0.7,
            topP: 0.95)
        return try JSONVariantParser.parse(raw)
    }

    func checkConnection() async throws {
        _ = try await complete(
            system: "You are MiMo, an AI assistant developed by Xiaomi. Return exactly: ok",
            user: "ok",
            maxTokens: 16,
            temperature: 0,
            topP: 0.95)
    }

    func transcribeAudio(dataURL: String, language: String?) async throws -> String {
        let key = apiKey.trimmed
        guard !key.isEmpty else { throw MimoError.notConfigured }

        var request = URLRequest(url: try resolvedBaseURL().appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 300

        let asrLanguage = Self.asrLanguage(from: language)
        let body: [String: Any] = [
            "model": "mimo-v2.5-asr",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": dataURL
                            ],
                        ]
                    ],
                ]
            ],
            "asr_options": [
                "language": asrLanguage
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw MimoError.http(status: http.statusCode, body: String(text.prefix(400)))
        }

        let decoded = try JSONDecoder.snakeCase.decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmed,
              !content.isEmpty
        else { throw MimoError.noContent }
        return content
    }

    func translateSubtitleSegments(
        _ segments: [TranscriptSegment],
        targetLanguage: String,
        contextTitle: String = "",
        contextSummary: String = ""
    ) async throws -> [TranscriptSegment] {
        let target = targetLanguage.trimmed
        guard !target.isEmpty, !segments.isEmpty else { return segments }

        var translatedByIndex: [Int: String] = [:]
        for chunkStart in stride(from: 0, to: segments.count, by: 40) {
            let chunkEnd = min(chunkStart + 40, segments.count)
            let chunk = Array(segments[chunkStart..<chunkEnd])
            let items = chunk.enumerated().map { offset, segment in
                [
                    "id": chunkStart + offset,
                    "start": segment.start,
                    "end": segment.end,
                    "text": TranscriptionService.cleanTranscriptText(segment.text),
                ] as [String: Any]
            }
            let before = segments[max(0, chunkStart - 6)..<chunkStart]
                .map { TranscriptionService.cleanTranscriptText($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let after = segments[chunkEnd..<min(segments.count, chunkEnd + 6)]
                .map { TranscriptionService.cleanTranscriptText($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let inputObject: [String: Any] = [
                "target_language": target,
                "segment_title": contextTitle.trimmed,
                "segment_summary": contextSummary.trimmed,
                "context_before": before,
                "context_after": after,
                "items": items,
            ]
            let inputData = try JSONSerialization.data(withJSONObject: inputObject, options: [.sortedKeys])
            let input = String(data: inputData, encoding: .utf8) ?? #"{"items":[]}"#

            let raw = try await complete(
                system: """
                You are a senior subtitle translator and Vietnamese copy editor.
                Translate subtitle cue text to \(target), using the surrounding
                context to preserve meaning across cue boundaries.

                Return ONLY valid JSON in this shape:
                {"items":[{"id":0,"text":"translated subtitle"}]}

                Rules:
                - Preserve every id exactly.
                - Return one output item for every input item, in the same order.
                - Read all items as one continuous spoken passage before translating.
                - Do not translate word by word. Use natural, fluent Vietnamese.
                - Repair obvious ASR and spelling errors when the intended meaning is clear.
                - Keep terminology consistent across the whole segment.
                - Resolve pronouns, implied subjects, and sentence flow from nearby cues.
                - Keep each cue concise enough for subtitles, but do not make it cryptic.
                - Use standard Vietnamese spelling, punctuation, capitalization, and diacritics.
                - Do not include timestamps, speaker labels, notes, markdown, or explanations.
                - Do not add new facts or change technical meaning.
                """,
                user: input,
                maxTokens: 4096,
                temperature: 0.1,
                topP: 0.9)
            if let object = JSONVariantParser.extractJSONObject(from: raw),
               let root = JSONVariantParser.deserializeTolerant(object) as? [String: Any],
               let output = root["items"] as? [[String: Any]] {
                for item in output {
                    guard let id = item["id"] as? Int,
                          let text = item["text"] as? String
                    else { continue }
                    let cleaned = TranscriptionService.cleanTranscriptText(text)
                    if !cleaned.isEmpty {
                        translatedByIndex[id] = cleaned
                    }
                }
            }
        }

        return segments.enumerated().map { index, segment in
            TranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: translatedByIndex[index] ?? segment.text)
        }
    }

    private func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double
    ) async throws -> String {
        let key = apiKey.trimmed
        guard !key.isEmpty else { throw MimoError.notConfigured }
        let model = modelID.trimmed.isEmpty ? "mimo-v2.5-pro" : modelID.trimmed

        var request = URLRequest(url: try resolvedBaseURL().appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 300

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            maxCompletionTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            stream: false,
            stop: nil,
            frequencyPenalty: 0,
            presencePenalty: 0,
            thinking: .disabled)
        request.httpBody = try JSONEncoder.snakeCase.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw MimoError.http(status: http.statusCode, body: String(text.prefix(400)))
        }

        let decoded = try JSONDecoder.snakeCase.decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmed,
              !content.isEmpty
        else { throw MimoError.noContent }
        return content
    }

    private func resolvedBaseURL() throws -> URL {
        let raw = baseURL.trimmed
        if !raw.isEmpty {
            guard let url = URL(string: raw) else { throw MimoError.invalidURL }
            return url.deletingTrailingSlash()
        }

        // Xiaomi uses separate hosts for pay-as-you-go (`sk-...`) and Token Plan
        // (`tp-...`) keys. Vietnam users usually receive the Singapore cluster.
        if apiKey.trimmed.hasPrefix("tp-") {
            return Self.defaultTokenPlanBaseURL
        }
        return Self.payAsYouGoBaseURL
    }

    private static func asrLanguage(from language: String?) -> String {
        switch (language ?? "").trimmed.lowercased() {
        case "en", "english", "inglés", "ingles":
            return "en"
        case "zh", "chinese", "mandarin", "中文", "普通话":
            return "zh"
        default:
            return "auto"
        }
    }

    private static func highlightSystemPrompt(language: String?) -> String {
        let lang = (language ?? "").trimmed
        let languageRule = lang.isEmpty
            ? "Write title, summary, segment titles, and why fields in the same language spoken in the transcript."
            : "Write title, summary, segment titles, and why fields in this language: \(lang)."

        return """
        You are an expert educational video editor and subtitle-aware summary \
        writer. You receive a timestamped transcript from a long lecture, \
        podcast, presentation, or interview. Your job is to create an edit \
        decision list for ONE coherent highlight video, not a set of shorts.

        Goal:
        - Make a 5 to 15 minute highlight video.
        - Preserve the strongest knowledge path: opening context, core concepts, \
        concrete examples, key warnings, and takeaways.
        - Favor sections whose spoken text can carry readable subtitles without \
        requiring missing visual context.
        - Remove slow delivery, repetition, filler, greetings, sponsorships, \
        long pauses, and rambling.
        - Keep each selected segment as a complete idea. Never cut mid-sentence.
        - Order segments by the best learning flow, usually chronological unless \
        moving a later segment earlier makes the mini-lesson clearer.
        - \(languageRule)

        Return ONLY valid JSON, with no markdown, no prose, using this shape:
        {
          "title": "short title for the highlight",
          "summary": "1-2 sentence summary of what the highlight teaches",
          "segments": [
            {
              "start": "MM:SS or HH:MM:SS",
              "end": "MM:SS or HH:MM:SS",
              "title": "short subtitle-friendly title for this idea",
              "why": "why this segment belongs in the highlight"
            }
          ]
        }

        Segment rules:
        - Prefer 6 to 14 segments.
        - Individual segments should usually be 20 to 180 seconds.
        - Total selected duration should be 300 to 900 seconds.
        - Titles should be calm, literal, and readable as on-screen labels.
        - Do not invent content outside the transcript.
        """
    }
}

enum HighlightPlanJSONParser {
    static let minSegmentDuration = 8.0
    static let maxSegmentDuration = 240.0
    static let maxTotalDuration = 15 * 60.0

    static func parse(_ raw: String, sourceDuration: Double) -> HighlightPlan {
        guard let jsonString = JSONVariantParser.extractJSONObject(from: raw),
              let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any]
        else {
            return HighlightPlan(title: "Highlight", summary: "", segments: [])
        }

        let title = string(root, "title", "headline").trimmed
        let summary = string(root, "summary", "description").trimmed
        let entries = (root["segments"] as? [[String: Any]])
            ?? (root["clips"] as? [[String: Any]])
            ?? []

        var total = 0.0
        var usedRanges: [(start: Double, end: Double)] = []
        var segments: [HighlightSegment] = []

        for entry in entries {
            guard let rawStart = MomentJSONParser.seconds(from: entry["start"]),
                  let rawEnd = MomentJSONParser.seconds(from: entry["end"])
            else { continue }

            let start = min(max(rawStart, 0), max(sourceDuration, 0))
            let end = min(max(rawEnd, start), max(sourceDuration, start))
            guard end > start else { continue }
            guard end - start >= minSegmentDuration else { continue }
            guard !usedRanges.contains(where: { rangesOverlap(start, end, $0.start, $0.end) }) else {
                continue
            }

            let cappedEnd = min(end, start + maxSegmentDuration)
            let duration = cappedEnd - start
            guard total + duration <= maxTotalDuration + 1 else { break }

            segments.append(HighlightSegment(
                start: start,
                end: cappedEnd,
                title: string(entry, "title", "hook", "topic"),
                why: string(entry, "why", "reason", "rationale")))
            usedRanges.append((start, cappedEnd))
            total += duration
        }

        return HighlightPlan(
            title: title.isEmpty ? "Highlight" : title,
            summary: summary,
            segments: segments)
    }

    private static func string(_ entry: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = (entry[key] as? String)?.trimmed, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func rangesOverlap(_ aStart: Double, _ aEnd: Double,
                                      _ bStart: Double, _ bEnd: Double) -> Bool {
        aStart < bEnd && bStart < aEnd
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let maxCompletionTokens: Int
    let temperature: Double
    let topP: Double
    let stream: Bool
    let stop: String?
    let frequencyPenalty: Double
    let presencePenalty: Double
    let thinking: Thinking

    struct Thinking: Encodable {
        let type: String

        static let disabled = Thinking(type: "disabled")
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private extension JSONEncoder {
    static var snakeCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

private extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension URL {
    func deletingTrailingSlash() -> URL {
        var absolute = absoluteString
        while absolute.hasSuffix("/") {
            absolute.removeLast()
        }
        return URL(string: absolute) ?? self
    }
}
