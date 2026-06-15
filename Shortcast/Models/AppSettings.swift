import Foundation
import Observation

/// User configuration: highlight, subtitle, publishing, and model preferences.
///
/// Everything (including the API key) lives in `UserDefaults`. The key used to
/// sit in the Keychain, but every dev rebuild changes the app's code signature,
/// so macOS re-prompted on each launch — for a 100% local/offline tool the
/// plist is a fine home. Held as an `@Observable` so views update on change.
@MainActor
@Observable
final class AppSettings {

    /// Legacy clip helper model. The headline long-video highlight flow uses
    /// MiMo for planning; these options remain for the older single-clip and
    /// generated-clip text helpers.
    enum CopywriterModel: String, CaseIterable, Identifiable, Sendable {
        case gemma12B = "gemma12b"
        case qwen35_9b = "qwen"
        case gemmaE4B = "gemma"
        case mimo = "mimo"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gemma12B:  "Gemma 4 12B"
            case .qwen35_9b: "Qwen 3.5 9B"
            case .gemmaE4B:  "Gemma 4 E4B · 4-bit"
            case .mimo:      "MiMo API"
            }
        }

        var tagline: String {
            switch self {
            case .gemma12B:  "Legacy helper for finding useful clip ranges and writing grounded summaries in one pass."
            case .qwen35_9b: "Legacy helper for lighter transcript-based clip summaries."
            case .gemmaE4B:  "Legacy helper that watches a clip (frames + audio) before writing a grounded summary."
            case .mimo:      "Uses Xiaomi MiMo through its OpenAI-compatible API for legacy clip summaries. Video processing stays local."
            }
        }

        /// The text model that finds the moments. The two inline options are
        /// their own Director; the clip-watching option still needs a Director,
        /// for which we use the default (Gemma 4 12B).
        var directorProfile: ChatModelProfile? {
            switch self {
            case .qwen35_9b:           return .qwen35_9b
            case .gemma12B, .gemmaE4B: return .gemma12B
            case .mimo:                return nil
            }
        }

        var directorDisplayName: String {
            switch self {
            case .mimo: return "MiMo API"
            default:    return directorProfile?.displayName ?? displayName
            }
        }

        /// True when the Director writes the captions in the same pass (so no
        /// separate per-clip captioning step runs).
        var usesInlineCaptions: Bool {
            switch self {
            case .gemma12B, .qwen35_9b, .mimo: true
            case .gemmaE4B:                    false
            }
        }

        /// True for the multimodal Gemma E4B path that watches each clip — the
        /// only option that loads a second model alongside the Director.
        var watchesClips: Bool { self == .gemmaE4B }

        var usesRemoteMimo: Bool { self == .mimo }
    }

    enum TikTokPublishMode: String, CaseIterable, Identifiable, Codable, Sendable {
        case inboxUpload
        case directPost

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .inboxUpload: "Inbox upload"
            case .directPost:  "Direct post"
            }
        }

        var requiredScope: String {
            switch self {
            case .inboxUpload: "video.upload"
            case .directPost:  "video.publish"
            }
        }
    }

    enum HighlightSubtitleLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
        case original
        case vietnamese

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .original: "Original transcript"
            case .vietnamese: "Vietnamese"
            }
        }

        var targetLanguage: String? {
            switch self {
            case .original: nil
            case .vietnamese: "Vietnamese"
            }
        }
    }

    enum TranscriptionBackend: String, CaseIterable, Identifiable, Codable, Sendable {
        case whisper
        case mimoASR

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .whisper: "WhisperKit large-v3"
            case .mimoASR: "MiMo V2.5 ASR"
            }
        }

        var detail: String {
            switch self {
            case .whisper:
                "Local, timestamped, slower on long videos."
            case .mimoASR:
                "Remote, best for Chinese/English, and faster; timestamps are chunk-level because the API returns text only."
            }
        }
    }

    /// Upload-Post API key. Mirrored to `UserDefaults` on every change.
    var apiKey: String {
        didSet { persistAPIKey() }
    }

    /// Upload-Post profile name (from "Manage Users" — NOT a social handle).
    var profileName: String {
        didSet { defaults.set(profileName, forKey: Keys.profile) }
    }

    /// Which publishing backend is used when pressing Publish.
    var publishingProvider: PublishingProviderID {
        didSet { defaults.set(publishingProvider.rawValue, forKey: Keys.publishingProvider) }
    }

    /// TikTok developer app metadata. The manual-token flow does not use these
    /// directly, but keeping them here makes the settings screen self-contained.
    var tiktokClientKey: String {
        didSet { defaults.set(tiktokClientKey, forKey: Keys.tiktokClientKey) }
    }

    var tiktokClientSecret: String {
        didSet { persistTikTokClientSecret() }
    }

    /// User access token obtained from TikTok OAuth with `video.upload` or
    /// `video.publish`, depending on `tiktokPublishMode`.
    var tiktokAccessToken: String {
        didSet { persistTikTokAccessToken() }
    }

    var tiktokPublishMode: TikTokPublishMode {
        didSet { defaults.set(tiktokPublishMode.rawValue, forKey: Keys.tiktokPublishMode) }
    }

    var tiktokPrivacyLevel: String {
        didSet { defaults.set(tiktokPrivacyLevel, forKey: Keys.tiktokPrivacyLevel) }
    }

    var tiktokDisableDuet: Bool {
        didSet { defaults.set(tiktokDisableDuet, forKey: Keys.tiktokDisableDuet) }
    }

    var tiktokDisableStitch: Bool {
        didSet { defaults.set(tiktokDisableStitch, forKey: Keys.tiktokDisableStitch) }
    }

    var tiktokDisableComment: Bool {
        didSet { defaults.set(tiktokDisableComment, forKey: Keys.tiktokDisableComment) }
    }

    var tiktokLabelAIGC: Bool {
        didSet { defaults.set(tiktokLabelAIGC, forKey: Keys.tiktokLabelAIGC) }
    }

    /// Xiaomi MiMo API key. Only used when the caption writer is set to MiMo.
    var mimoAPIKey: String {
        didSet { persistMimoAPIKey() }
    }

    /// Xiaomi model id for the OpenAI-compatible Chat Completions API.
    var mimoModelID: String {
        didSet { defaults.set(mimoModelID, forKey: Keys.mimoModel) }
    }

    /// Speech-to-text backend for long-video highlights.
    var transcriptionBackend: TranscriptionBackend {
        didSet { defaults.set(transcriptionBackend.rawValue, forKey: Keys.transcriptionBackend) }
    }

    /// Optional Xiaomi MiMo OpenAI-compatible base URL. Token Plan users receive
    /// a region-specific URL; empty lets the service infer a sensible default.
    var mimoBaseURL: String {
        didSet { defaults.set(mimoBaseURL, forKey: Keys.mimoBaseURL) }
    }

    /// Optional output language override (e.g. "English", "vi"). Empty = match
    /// the language spoken in the video.
    var languageOverride: String {
        didSet { defaults.set(languageOverride, forKey: Keys.language) }
    }

    /// Optional examples of the user's own notes or summaries, fed to the model as style.
    var styleExamples: String {
        didSet { defaults.set(styleExamples, forKey: Keys.style) }
    }

    /// When true, TikTok uploads land in the inbox as a draft instead of
    /// publishing directly (`post_mode=MEDIA_UPLOAD`). On by default.
    var tiktokAsDraft: Bool {
        didSet { defaults.set(tiktokAsDraft, forKey: Keys.tiktokDraft) }
    }

    /// The legacy helper model used to summarize generated clips.
    var copywriterModel: CopywriterModel {
        didSet { defaults.set(copywriterModel.rawValue, forKey: Keys.copywriter) }
    }

    /// Default for burning an AI text hook into the top of each generated short.
    /// Per-clip toggles can override this.
    var burnHookOverlay: Bool {
        didSet { defaults.set(burnHookOverlay, forKey: Keys.burnHook) }
    }

    /// Default for reframing a horizontal (16:9) clip to vertical 9:16, tracking
    /// the speaker with Vision. Only applies to clips that are actually
    /// landscape; per-clip toggles can override this.
    var reframeToVertical: Bool {
        didSet { defaults.set(reframeToVertical, forKey: Keys.reframe) }
    }

    /// Output aspect ratio for the long-video highlight renderer.
    var highlightAspectMode: HighlightAspectMode {
        didSet { defaults.set(highlightAspectMode.rawValue, forKey: Keys.highlightAspect) }
    }

    /// Whether rendered highlights begin with a generated title/table-of-contents card.
    var showHighlightIntroCard: Bool {
        didSet { defaults.set(showHighlightIntroCard, forKey: Keys.showHighlightIntroCard) }
    }

    /// Language used for burned-in subtitles on long-video highlights.
    var highlightSubtitleLanguage: HighlightSubtitleLanguage {
        didSet { defaults.set(highlightSubtitleLanguage.rawValue, forKey: Keys.highlightSubtitleLanguage) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // API key now lives in UserDefaults. If a value is still in the Keychain
        // from an older build, migrate it once and clear it from the Keychain.
        if let stored = defaults.string(forKey: Keys.apiKey), !stored.isEmpty {
            self.apiKey = stored
        } else if let legacy = KeychainStore.read(account: Keys.legacyApiKey),
                  !legacy.isEmpty {
            self.apiKey = legacy
            defaults.set(legacy, forKey: Keys.apiKey)
            KeychainStore.delete(account: Keys.legacyApiKey)
        } else {
            self.apiKey = ""
        }
        self.mimoAPIKey = defaults.string(forKey: Keys.mimoAPIKey) ?? ""
        self.mimoModelID = defaults.string(forKey: Keys.mimoModel) ?? "mimo-v2.5-pro"
        self.mimoBaseURL = defaults.string(forKey: Keys.mimoBaseURL) ?? ""
        self.transcriptionBackend = defaults.string(forKey: Keys.transcriptionBackend)
            .flatMap(TranscriptionBackend.init) ?? .whisper
        self.profileName = defaults.string(forKey: Keys.profile) ?? ""
        self.publishingProvider = defaults.string(forKey: Keys.publishingProvider)
            .flatMap(PublishingProviderID.init) ?? .uploadPost
        self.tiktokClientKey = defaults.string(forKey: Keys.tiktokClientKey) ?? ""
        self.tiktokClientSecret = defaults.string(forKey: Keys.tiktokClientSecret) ?? ""
        self.tiktokAccessToken = defaults.string(forKey: Keys.tiktokAccessToken) ?? ""
        self.tiktokPublishMode = defaults.string(forKey: Keys.tiktokPublishMode)
            .flatMap(TikTokPublishMode.init) ?? .inboxUpload
        self.tiktokPrivacyLevel = defaults.string(forKey: Keys.tiktokPrivacyLevel) ?? "SELF_ONLY"
        self.tiktokDisableDuet = defaults.object(forKey: Keys.tiktokDisableDuet) as? Bool ?? false
        self.tiktokDisableStitch = defaults.object(forKey: Keys.tiktokDisableStitch) as? Bool ?? false
        self.tiktokDisableComment = defaults.object(forKey: Keys.tiktokDisableComment) as? Bool ?? false
        self.tiktokLabelAIGC = defaults.object(forKey: Keys.tiktokLabelAIGC) as? Bool ?? false
        self.languageOverride = defaults.string(forKey: Keys.language) ?? ""
        self.styleExamples = defaults.string(forKey: Keys.style) ?? ""
        // Defaults to true on first launch (no stored value yet).
        self.tiktokAsDraft = defaults.object(forKey: Keys.tiktokDraft) as? Bool ?? true
        // Default to Gemma 4 12B for legacy clip helpers.
        self.copywriterModel = defaults.string(forKey: Keys.copywriter)
            .flatMap(CopywriterModel.init) ?? .gemma12B
        // Default on — the user opted into the hook-overlay feature.
        self.burnHookOverlay = defaults.object(forKey: Keys.burnHook) as? Bool ?? true
        // Default on — horizontal clips should become vertical shorts.
        self.reframeToVertical = defaults.object(forKey: Keys.reframe) as? Bool ?? true
        self.highlightAspectMode = defaults.string(forKey: Keys.highlightAspect)
            .flatMap(HighlightAspectMode.init) ?? .vertical
        self.showHighlightIntroCard = defaults.object(forKey: Keys.showHighlightIntroCard) as? Bool ?? false
        self.highlightSubtitleLanguage = defaults.string(forKey: Keys.highlightSubtitleLanguage)
            .flatMap(HighlightSubtitleLanguage.init) ?? .original
    }

    /// True once the app has enough to publish.
    var isConfigured: Bool {
        switch publishingProvider {
        case .uploadPost:
            !apiKey.trimmed.isEmpty && !profileName.trimmed.isEmpty
        case .tiktokOfficial:
            !tiktokAccessToken.trimmed.isEmpty
        }
    }

    var activePublishingProvider: any PublishingProvider {
        PublishingProviderFactory.make(publishingProvider)
    }

    private func persistAPIKey() {
        let trimmed = apiKey.trimmed
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.apiKey)
        } else {
            defaults.set(trimmed, forKey: Keys.apiKey)
        }
    }

    private func persistMimoAPIKey() {
        let trimmed = mimoAPIKey.trimmed
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.mimoAPIKey)
        } else {
            defaults.set(trimmed, forKey: Keys.mimoAPIKey)
        }
    }

    private func persistTikTokClientSecret() {
        let trimmed = tiktokClientSecret.trimmed
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.tiktokClientSecret)
        } else {
            defaults.set(trimmed, forKey: Keys.tiktokClientSecret)
        }
    }

    private func persistTikTokAccessToken() {
        let trimmed = tiktokAccessToken.trimmed
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Keys.tiktokAccessToken)
        } else {
            defaults.set(trimmed, forKey: Keys.tiktokAccessToken)
        }
    }

    private enum Keys {
        static let profile     = "shortcast.profileName"
        static let publishingProvider = "shortcast.publishingProvider"
        static let tiktokClientKey = "shortcast.tiktok.clientKey"
        static let tiktokClientSecret = "shortcast.tiktok.clientSecret"
        static let tiktokAccessToken = "shortcast.tiktok.accessToken"
        static let tiktokPublishMode = "shortcast.tiktok.publishMode"
        static let tiktokPrivacyLevel = "shortcast.tiktok.privacyLevel"
        static let tiktokDisableDuet = "shortcast.tiktok.disableDuet"
        static let tiktokDisableStitch = "shortcast.tiktok.disableStitch"
        static let tiktokDisableComment = "shortcast.tiktok.disableComment"
        static let tiktokLabelAIGC = "shortcast.tiktok.labelAIGC"
        static let mimoAPIKey  = "shortcast.mimo.apiKey"
        static let mimoModel   = "shortcast.mimo.model"
        static let mimoBaseURL = "shortcast.mimo.baseURL"
        static let transcriptionBackend = "shortcast.transcription.backend"
        static let language    = "shortcast.languageOverride"
        static let style       = "shortcast.styleExamples"
        static let tiktokDraft = "shortcast.tiktokAsDraft"
        static let copywriter  = "shortcast.copywriterModel"
        static let burnHook    = "shortcast.burnHookOverlay"
        static let reframe     = "shortcast.reframeToVertical"
        static let highlightAspect = "shortcast.highlight.aspectMode"
        static let showHighlightIntroCard = "shortcast.highlight.showIntroCard"
        static let highlightSubtitleLanguage = "shortcast.highlight.subtitleLanguage"
        static let apiKey      = "shortcast.apiKey"
        /// Old Keychain account, read once to migrate into UserDefaults.
        static let legacyApiKey = "upload-post-api-key"
    }
}
