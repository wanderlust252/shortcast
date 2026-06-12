import SwiftUI

/// The single configuration screen (⌘,): Upload-Post account, caption style,
/// publishing options, and model status.
struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager

    private enum ConnectionState: Equatable {
        case idle, checking, ok, failed(String)
    }
    @State private var connection: ConnectionState = .idle
    @State private var tiktokConnection: ConnectionState = .idle
    @State private var mimoConnection: ConnectionState = .idle

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Publishing provider") {
                Picker("Provider", selection: $settings.publishingProvider) {
                    ForEach(PublishingProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text(settings.publishingProvider == .uploadPost
                     ? "Upload-Post publishes TikTok, Instagram Reels and YouTube Shorts."
                     : "TikTok official API uploads only the TikTok variant. Instagram and YouTube are not sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Upload-Post account") {
                SecureField("API key", text: $settings.apiKey)
                TextField("Profile name", text: $settings.profileName)

                Text("Create an API key and a profile in the Upload-Post dashboard. The profile name is the one from **Manage Users** — not your social handle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Test connection", action: testConnection)
                        .disabled(settings.apiKey.trimmed.isEmpty || connection == .checking)
                    connectionStatus
                    Spacer()
                    Link("Connect accounts ↗", destination: URL(string: "https://app.upload-post.com")!)
                }
            }

            Section("TikTok official API") {
                TextField("Client key", text: $settings.tiktokClientKey)
                SecureField("Client secret", text: $settings.tiktokClientSecret)
                SecureField("User access token", text: $settings.tiktokAccessToken)

                Picker("Mode", selection: $settings.tiktokPublishMode) {
                    ForEach(AppSettings.TikTokPublishMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text("Paste a TikTok user access token with scope **\(settings.tiktokPublishMode.requiredScope)**. Client key/secret are stored for reference; this build does not run OAuth automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.tiktokPublishMode == .directPost {
                    Picker("Privacy", selection: $settings.tiktokPrivacyLevel) {
                        Text("Self only").tag("SELF_ONLY")
                        Text("Public").tag("PUBLIC_TO_EVERYONE")
                        Text("Followers").tag("FOLLOWER_OF_CREATOR")
                        Text("Mutual friends").tag("MUTUAL_FOLLOW_FRIENDS")
                    }
                    Toggle("Disable comments", isOn: $settings.tiktokDisableComment)
                    Toggle("Disable duet", isOn: $settings.tiktokDisableDuet)
                    Toggle("Disable stitch", isOn: $settings.tiktokDisableStitch)
                    Toggle("Label as AI-generated", isOn: $settings.tiktokLabelAIGC)

                    Text("Direct Post must use one of the privacy options returned by TikTok for the account. If Public fails, try Self only or query creator info with Test TikTok.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Inbox upload sends only the video file to TikTok. Finish caption, privacy and posting inside TikTok.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Test TikTok", action: testTikTokConnection)
                        .disabled(settings.tiktokAccessToken.trimmed.isEmpty || tiktokConnection == .checking)
                    statusView(tiktokConnection)
                    Spacer()
                    Link("TikTok docs ↗", destination: URL(string: "https://developers.tiktok.com/doc/content-posting-api-reference-upload-video")!)
                }
            }

            Section("Captions") {
                TextField(
                    "Language",
                    text: $settings.languageOverride,
                    prompt: Text("Auto-detect from the video"))
                Text("Optional. Set to `Vietnamese` or `vi` to force Whisper transcription and model outputs to Vietnamese.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your style examples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.styleExamples)
                        .font(.body)
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    Text("Optional. Paste a few captions you like — the model will match your voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Publishing") {
                Toggle("Upload TikTok as a draft", isOn: $settings.tiktokAsDraft)
                Text("Used by Upload-Post. For TikTok official API, choose Inbox upload or Direct post in the TikTok section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Xiaomi MiMo") {
                SecureField("MiMo API key", text: $settings.mimoAPIKey)
                TextField("Model", text: $settings.mimoModelID, prompt: Text("mimo-v2.5-pro"))
                TextField("Base URL", text: $settings.mimoBaseURL, prompt: Text(mimoBaseURLPrompt))

                Text("Used only when Caption writer is set to MiMo API. For Token Plan keys (`tp-...`), use the Base URL from Subscription Management; empty defaults to Singapore. Pay-as-you-go keys (`sk-...`) use the public API endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Test MiMo", action: testMimoConnection)
                        .disabled(settings.mimoAPIKey.trimmed.isEmpty || mimoConnection == .checking)
                    mimoConnectionStatus
                    Spacer()
                    Link("MiMo console ↗", destination: URL(string: "https://platform.xiaomimimo.com")!)
                }
            }

            Section("How a long video becomes a highlight") {
                Picker("Transcription", selection: $settings.transcriptionBackend) {
                    ForEach(AppSettings.TranscriptionBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.transcriptionBackend.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                pipelineRole(
                    step: "1", icon: "waveform",
                    title: "Transcribe",
                    model: settings.transcriptionBackend.displayName,
                    detail: "Turns the audio into text. Runs only when the video has no .srt/.vtt next to it.",
                    status: settings.transcriptionBackend == .mimoASR && settings.mimoAPIKey.trimmed.isEmpty ? "Needs MiMo key" : nil)
                pipelineRole(
                    step: "2", icon: "wand.and.stars",
                    title: "Plan the highlight",
                    model: "MiMo API",
                    detail: "Reads the timestamped transcript and returns the sections for one coherent 5-15 minute edit.",
                    status: settings.mimoAPIKey.trimmed.isEmpty ? "Needs API key" : "Remote API")
                pipelineRole(
                    step: "3", icon: "film",
                    title: "Render",
                    model: settings.highlightAspectMode.displayName,
                    detail: "Cuts the selected source ranges and joins them into one downloadable video.",
                    status: nil)
            }

            Section("Highlight output") {
                Picker("Aspect ratio", selection: $settings.highlightAspectMode) {
                    ForEach(HighlightAspectMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Vertical 9:16 is ready for social posting. Original ratio preserves slides and wide interview framing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Subtitle language", selection: $settings.highlightSubtitleLanguage) {
                    ForEach(AppSettings.HighlightSubtitleLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Original uses the transcript as-is. Vietnamese translates only the selected highlight subtitle cues before rendering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Caption writer") {
                Picker("Model", selection: $settings.copywriterModel) {
                    ForEach(AppSettings.CopywriterModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(settings.copywriterModel.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Used by the legacy shorts helpers and captioning paths. The long-video highlight planner always uses MiMo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.copywriterModel.usesRemoteMimo && settings.mimoAPIKey.trimmed.isEmpty {
                    Label("Add a MiMo API key above before processing a long video with MiMo.",
                          systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if settings.copywriterModel.watchesClips && modelManager.systemRAMGB < 24 {
                    Label("On this Mac, Shortcast frees the moment-finder before captioning to stay within memory.",
                          systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Text hook overlay") {
                Toggle("Burn an AI text hook into each short", isOn: $settings.burnHookOverlay)
                Text("Shows a short hook over the top of each clip for the first few seconds. The default for new shorts — you can flip it per clip. The text is rendered into the video when you publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vertical reframing") {
                Toggle("Auto-convert horizontal clips to vertical 9:16", isOn: $settings.reframeToVertical)
                Text("Tracks the speaker with on-device Vision and reframes 16:9 → 9:16, falling back to a blurred background when there's no clear face. The default for new horizontal clips — you can flip it per clip. Applied when you publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("This Mac") {
                LabeledContent("Memory", value: "\(modelManager.systemRAMGB) GB")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
    }

    // MARK: - Connection test

    @ViewBuilder
    private var connectionStatus: some View {
        statusView(connection)
    }

    @ViewBuilder
    private var mimoConnectionStatus: some View {
        statusView(mimoConnection)
    }

    @ViewBuilder
    private func statusView(_ state: ConnectionState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func testConnection() {
        connection = .checking
        let provider = UploadPostProvider()
        Task {
            do {
                try await provider.checkConnection(settings: settings)
                connection = .ok
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func testTikTokConnection() {
        tiktokConnection = .checking
        let provider = TikTokOfficialProvider()
        Task {
            do {
                try await provider.checkConnection(settings: settings)
                tiktokConnection = .ok
            } catch {
                tiktokConnection = .failed(error.localizedDescription)
            }
        }
    }

    private func testMimoConnection() {
        mimoConnection = .checking
        let client = MimoService(
            apiKey: settings.mimoAPIKey,
            modelID: settings.mimoModelID,
            baseURL: settings.mimoBaseURL)
        Task {
            do {
                try await client.checkConnection()
                mimoConnection = .ok
            } catch {
                mimoConnection = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func pipelineRole(step: String, icon: String, title: String,
                             model: String, detail: String, status: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(step). \(title)").font(.callout.weight(.semibold))
                    Spacer()
                    Text(model).font(.callout).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let status {
                    Text(status).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var modelStatus: String {
        switch modelManager.phase {
        case .idle:                          "Not loaded"
        case .downloading(let fraction, _):  "Downloading \(Int(fraction * 100))%"
        case .loading:                       "Loading…"
        case .ready:                         "Ready"
        case .failed:                        "Failed to load"
        }
    }

    private var directorStatus: String {
        switch modelManager.momentFinder.phase {
        case .idle:                        "Loads on first long video"
        case .downloading(let fraction):   "Downloading \(Int(fraction * 100))%"
        case .loading:                     "Loading…"
        case .ready:                       "Ready"
        case .failed:                      "Failed to load"
        }
    }

    private var selectedDirectorStatus: String {
        settings.copywriterModel.usesRemoteMimo ? "Remote API" : directorStatus
    }

    private var selectedCaptionStatus: String {
        if settings.copywriterModel.usesRemoteMimo { return "Remote API" }
        return settings.copywriterModel.watchesClips ? modelStatus : directorStatus
    }

    private var mimoBaseURLPrompt: String {
        settings.mimoAPIKey.trimmed.hasPrefix("tp-")
            ? "https://token-plan-sgp.xiaomimimo.com/v1"
            : "https://api.xiaomimimo.com/v1"
    }
}
