import SwiftUI
import UniformTypeIdentifiers

/// The idle state: a big drag-and-drop target for a short video.
struct DropZoneView: View {

    let isDropTargeted: Bool
    let onChooseFile: (URL) -> Void
    let onChooseAudio: (URL) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @State private var showingImporter = false
    @State private var showingAudioImporter = false
    @State private var isAudioDropTargeted = false

    var body: some View {
        @Bindable var settings = settings
        @Bindable var workspace = workspace

        VStack(spacing: 18) {
            Spacer()

            Picker("Mode", selection: $workspace.inputMode) {
                ForEach(WorkspaceModel.InputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)

            if workspace.inputMode == .shorts || workspace.inputMode == .translateFullVideo {
                Picker("Aspect ratio", selection: $settings.highlightAspectMode) {
                    ForEach(HighlightAspectMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            dropArea

            if workspace.canUseExternalAudio {
                audioDropArea
            }

            if let error = workspace.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Spacer()

            Text(privacyNote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            if case .success(let url) = result { onChooseFile(url) }
        }
        .fileImporter(
            isPresented: $showingAudioImporter,
            allowedContentTypes: [.audio]
        ) { result in
            if case .success(let url) = result { onChooseAudio(url) }
        }
    }

    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: workspace.inputMode.symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Text(workspace.inputMode.dropTitle)
                .font(.title2.weight(.semibold))

            Text(workspace.inputMode.dropSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Choose video…") { showingImporter = true }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: 560, minHeight: 320)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isDropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                     : AnyShapeStyle(Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var audioDropArea: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(isAudioDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("Separate audio for transcription")
                    .font(.callout.weight(.semibold))
                Text(workspace.externalAudioFileName ?? "Optional MP3, M4A, WAV, AIFF, CAF, AAC")
                    .font(.footnote)
                    .foregroundStyle(workspace.externalAudioFileName == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if workspace.externalAudioFileName != nil {
                Button {
                    workspace.removeExternalAudio()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove audio")
            }

            Button {
                showingAudioImporter = true
            } label: {
                Label("Choose audio", systemImage: "music.note")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isAudioDropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                          : AnyShapeStyle(Color.secondary.opacity(0.06)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isAudioDropTargeted ? Color.accentColor : Color.secondary.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !workspace.isBusy,
                  let url = urls.first(where: { $0.isFileURL })
            else { return false }
            onChooseAudio(url)
            return true
        } isTargeted: { isAudioDropTargeted = $0 }
        .animation(.easeInOut(duration: 0.15), value: isAudioDropTargeted)
    }

    private var privacyNote: String {
        switch workspace.inputMode {
        case .shorts:
            "The video stays on your Mac. For highlights, the timestamped transcript is sent to MiMo to plan the edit."
        case .translateFullVideo:
            "The video stays on your Mac. For translation, subtitle text is sent to MiMo in chunks."
        case .caption:
            "The video stays on your Mac. Legacy summaries only load Gemma when this mode runs."
        }
    }
}
