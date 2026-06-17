import SwiftUI
import UniformTypeIdentifiers

/// Root view and state machine: drop → processing → results. Local Gemma loads
/// lazily only when a legacy helper needs it.
struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace

    @State private var isDropTargeted = false

    var body: some View {
        workspaceContent
        .animation(.smooth(duration: 0.32), value: workspace.phase)
        .frame(minWidth: 1000, minHeight: 720)
        .dropDestination(for: URL.self) { urls, _ in
            guard !workspace.isBusy,
                  let url = urls.first(where: { $0.isFileURL })
            else { return false }
            if workspace.canUseExternalAudio, Self.looksLikeAudioFile(url) {
                chooseExternalAudio(url)
            } else {
                startProcessing(url)
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspace.phase {
        case .empty:
            DropZoneView(
                isDropTargeted: isDropTargeted,
                onChooseFile: startProcessing,
                onChooseAudio: chooseExternalAudio)
        case .processing:
            ProcessingView()
        case .results:
            ResultsView()
        case .transcribing, .findingMoments, .translatingSubtitles, .renderingHighlight, .renderingTranslatedVideo:
            ShortsProgressView()
        case .reviewingSubtitles:
            SubtitleReviewView()
        case .highlightResults:
            HighlightResultsView()
        case .translatedVideoResults:
            TranslatedVideoResultsView()
        case .shortsResults:
            ShortsResultsView()
        }
    }

    private func startProcessing(_ url: URL) {
        Task {
            await workspace.process(url: url, modelManager: modelManager, settings: settings)
        }
    }

    private func chooseExternalAudio(_ url: URL) {
        Task {
            await workspace.attachExternalAudio(url: url)
        }
    }

    private static func looksLikeAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return [
            "aac", "aif", "aiff", "caf", "flac", "m4a", "m4b",
            "mp3", "mp4a", "oga", "ogg", "wav", "wave", "wma",
        ].contains(ext)
    }
}
