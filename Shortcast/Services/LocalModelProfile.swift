import Foundation
import Gemma4Swift

/// Shortcast-owned model catalog. This keeps product choices out of the loader
/// code so adding or disabling a model is a data change first.
struct LocalModelProfile: Identifiable, Sendable {
    enum Role: Sendable {
        case directorText
        case multimodalCopywriter
    }

    enum Loader: Sendable {
        case mlxVLM
        case gemma4Text
        case gemma4Multimodal
    }

    struct Capabilities: OptionSet, Sendable {
        let rawValue: Int

        static let text = Capabilities(rawValue: 1 << 0)
        static let image = Capabilities(rawValue: 1 << 1)
        static let audio = Capabilities(rawValue: 1 << 2)
        static let video = Capabilities(rawValue: 1 << 3)
    }

    let id: String
    let displayName: String
    let role: Role
    let modelID: String
    let loader: Loader
    let quantizationLabel: String
    let estimatedDownloadGB: Float
    let recommendedRAMGB: Int
    let capabilities: Capabilities
    let sampling: SamplingConfig?

    var compactLabel: String {
        "\(displayName) · \(quantizationLabel)"
    }

    static let qwen35_9b = LocalModelProfile(
        id: "qwen35_9b",
        displayName: "Qwen 3.5 9B",
        role: .directorText,
        modelID: "mlx-community/Qwen3.5-9B-MLX-4bit",
        loader: .mlxVLM,
        quantizationLabel: "4-bit MLX",
        estimatedDownloadGB: 5.0,
        recommendedRAMGB: 8,
        capabilities: [.text],
        sampling: SamplingConfig(
            temperature: 0.7, topP: 0.8, topK: 20, minP: 0,
            repetitionPenalty: nil, maxTokens: 4096,
            maxKVSize: 40960, kvBits: 8))

    static let gemma12B = LocalModelProfile(
        id: "gemma12b",
        displayName: "Gemma 4 12B",
        role: .directorText,
        modelID: "mlx-community/gemma-4-12B-it-4bit",
        loader: .gemma4Text,
        quantizationLabel: "4-bit MLX",
        estimatedDownloadGB: 7.0,
        recommendedRAMGB: 12,
        capabilities: [.text],
        sampling: SamplingConfig(
            temperature: 0.35, topP: 0.9, topK: 30, minP: 0,
            repetitionPenalty: 1.1, maxTokens: 4096,
            maxKVSize: nil, kvBits: nil))

    static let gemmaE4B = LocalModelProfile(
        id: "gemma_e4b",
        displayName: "Gemma 4 E4B",
        role: .multimodalCopywriter,
        modelID: "mlx-community/gemma-4-e4b-it-4bit",
        loader: .gemma4Multimodal,
        quantizationLabel: "4-bit MLX",
        estimatedDownloadGB: 5.0,
        recommendedRAMGB: 7,
        capabilities: [.text, .image, .audio, .video],
        sampling: nil)

    static let directorProfiles: [LocalModelProfile] = [
        .gemma12B, .qwen35_9b
    ]

    static let multimodalProfiles: [LocalModelProfile] = [
        .gemmaE4B
    ]
}
