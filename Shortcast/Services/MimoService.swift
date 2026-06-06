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
            user: "Video transcript with timestamps:\n\n\(transcript)\n\nReturn the clips JSON.",
            maxTokens: 8192,
            temperature: 0.7,
            topP: 0.95)
        let clips = MomentJSONParser.parse(raw)
        guard !clips.isEmpty else { throw MomentFinderError.noClips }
        return clips
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
