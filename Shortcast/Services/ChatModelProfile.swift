import Foundation

/// Per-model decoding configuration for the MLX text models Shortcast loads
/// directly (currently just Qwen 3.5 9B, the "Director" that finds viral
/// moments). Adapted from Hermes-Jarvis, trimmed to what Shortcast needs.
///
/// MLX `GenerateParameters` defaults are generic; each model family has its
/// own vendor-recommended sampling that materially affects quality and memory.
struct SamplingConfig: Sendable {
    var temperature: Float
    var topP: Float
    /// 0 disables top-k.
    var topK: Int
    /// 0 disables min-p.
    var minP: Float
    /// nil → no repetition penalty.
    var repetitionPenalty: Float?
    /// Hard cap on generated tokens.
    var maxTokens: Int
    /// nil → unbounded (full) KV cache; set to bound memory.
    var maxKVSize: Int?
    /// nil → no KV quantization.
    var kvBits: Int?
}

struct ChatModelProfile: Sendable {
    /// HuggingFace repo id for the main model.
    let modelID: String
    /// Display name shown in UI.
    let displayName: String

    enum FactoryKind { case llm, vlm }
    /// LLM for text-only models; VLM for multimodal packages (Qwen 3.5 9B only
    /// exists in vision-language form on HF, so it loads via VLMModelFactory).
    let factoryKind: FactoryKind

    /// How the weights get turned into a `ModelContainer`. Both paths produce a
    /// container that drives the same `ChatSession` text generation — they only
    /// differ in how the architecture is registered/loaded.
    enum Loader {
        /// Standard mlx-swift-lm factory (Qwen 3.5 ships as a VLM package).
        case vlm
        /// Gemma 4 — register the custom "gemma4" type (text-only) via the
        /// vendored Gemma4Swift package, then load with its tokenizer loader.
        case gemma4Text
    }
    let loader: Loader

    /// Vendor-recommended decoding parameters.
    let sampling: SamplingConfig

    init(local profile: LocalModelProfile) {
        precondition(profile.role == .directorText)
        guard let sampling = profile.sampling else {
            preconditionFailure("Director profiles must have a model id and sampling config.")
        }
        self.modelID = profile.modelID
        self.displayName = profile.displayName
        switch profile.loader {
        case .mlxVLM:
            self.factoryKind = .vlm
            self.loader = .vlm
        case .gemma4Text:
            self.factoryKind = .llm
            self.loader = .gemma4Text
        case .gemma4Multimodal:
            preconditionFailure("Multimodal profiles cannot be used as text Directors.")
        }
        self.sampling = sampling
    }

    /// Qwen 3.5 9B — best multilingual reasoning in the small-model tier, huge
    /// context window (the whole transcript fits in one pass). Loads as a VLM.
    static let qwen35_9b = ChatModelProfile(local: .qwen35_9b)

    /// Gemma 4 12B — Google's new dense 12B (text+vision). We feed it the
    /// transcript text only, so it runs as a text LLM through the same
    /// `ChatSession` path as Qwen, via the vendored Gemma4Swift registration.
    /// The default Director: stronger writing than Qwen at a similar footprint.
    static let gemma12B = ChatModelProfile(local: .gemma12B)
}
