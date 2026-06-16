import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HighlightResultsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @State private var player: AVPlayer?
    @State private var exportError: String?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            header
            Divider()

            if let highlight = workspace.highlightVideo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top, spacing: 22) {
                            ZStack {
                                Color.black
                                if let player {
                                    VideoPlayer(player: player)
                                }
                            }
                            .aspectRatio(highlight.aspectMode == .vertical ? 9.0 / 16.0 : 16.0 / 9.0,
                                         contentMode: .fit)
                            .frame(maxWidth: 620, maxHeight: 620)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            details(highlight)
                                .frame(width: 330, alignment: .topLeading)
                        }

                        Toggle(isOn: $settings.suggestHighlightPublishingCopy) {
                            Label("Suggest captions and hashtags", systemImage: "number")
                                .font(.headline)
                        }
                        .toggleStyle(.switch)

                        if settings.suggestHighlightPublishingCopy {
                            publishingCopyPanel(highlight)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    let p = AVPlayer(url: highlight.url)
                    p.play()
                    player = p
                }
                .onDisappear { player?.pause() }
            } else {
                ContentUnavailableView("No highlight video", systemImage: "video.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
    }

    @ViewBuilder
    private func publishingCopyPanel(_ highlight: HighlightVideo) -> some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Publishing copy")
                        .font(.subheadline.weight(.semibold))
                    Text("Editable captions and hashtags for the rendered highlight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.isGeneratingHighlightCopy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await workspace.generateHighlightPublishingCopy(settings: settings) }
                    } label: {
                        Label(workspace.highlightVariants.isEmpty ? "Generate" : "Regenerate",
                              systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.mimoAPIKey.trimmed.isEmpty)
                    .help(settings.mimoAPIKey.trimmed.isEmpty
                          ? "Add a MiMo API key in Settings first."
                          : "Generate caption and hashtag suggestions")
                }
            }

            if let error = workspace.highlightCopyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if settings.mimoAPIKey.trimmed.isEmpty {
                Label("Add a MiMo API key in Settings to generate captions and hashtags.",
                      systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !workspace.highlightVariants.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    ForEach($workspace.highlightVariants) { $variant in
                        PostPreviewCard(variant: $variant, videoURL: highlight.url)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.tv")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.highlightVideo?.plan.title ?? workspace.job?.fileName ?? "Highlight")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let job = workspace.job {
                    Text(job.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                workspace.startOver()
            } label: {
                Label("Start over", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func details(_ highlight: HighlightVideo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                statChip(highlight.durationLabel, "clock")
                statChip("\(highlight.plan.segments.count) segments", "list.bullet")
            }
            statChip(highlight.aspectMode.displayName, "aspectratio")

            if !highlight.plan.summary.isEmpty {
                Text(highlight.plan.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(highlight.plan.segments) { segment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(segment.title.isEmpty ? segment.rangeLabel : segment.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Label("Source \(segment.rangeLabel)", systemImage: "film")
                                Text("-")
                                Label("Output \(highlight.outputRangeLabel(for: segment))",
                                      systemImage: "play.rectangle")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            if !segment.why.isEmpty {
                                Text(segment.why)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func statChip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private var footer: some View {
        HStack {
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Menu {
                Button("ASR/source subtitles (.srt)") {
                    runSubtitleSavePanel(kind: .source)
                }
                .disabled(workspace.highlightVideo?.subtitleSRT(kind: .source) == nil)

                Button("Rendered subtitles (.srt)") {
                    runSubtitleSavePanel(kind: .rendered)
                }
                .disabled(workspace.highlightVideo?.subtitleSRT(kind: .rendered) == nil)
            } label: {
                Label("Download subtitles", systemImage: "captions.bubble")
                    .frame(minWidth: 170)
            }
            .controlSize(.large)
            .disabled(workspace.highlightVideo == nil)

            Button {
                runSavePanel()
            } label: {
                Label("Download highlight", systemImage: "arrow.down.circle.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(workspace.highlightVideo == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func runSavePanel() {
        guard let highlight = workspace.highlightVideo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedFileName(for: highlight)
        panel.canCreateDirectories = true
        panel.title = "Download highlight"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: highlight.url, to: destination)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func runSubtitleSavePanel(kind: SubtitleExportKind) {
        guard let highlight = workspace.highlightVideo,
              let srt = highlight.subtitleSRT(kind: kind)
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = suggestedSubtitleFileName(for: highlight, kind: kind)
        panel.canCreateDirectories = true
        panel.title = "Download subtitles"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try srt.write(to: destination, atomically: true, encoding: .utf8)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func suggestedFileName(for highlight: HighlightVideo) -> String {
        let base = highlight.plan.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "highlight" : String(base.prefix(48))) + ".mp4"
    }

    private func suggestedSubtitleFileName(for highlight: HighlightVideo, kind: SubtitleExportKind) -> String {
        let base = highlight.plan.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix: String
        switch kind {
        case .source:
            suffix = "source"
        case .rendered:
            suffix = "rendered"
        }
        return "\(base.isEmpty ? "highlight" : String(base.prefix(42)))-\(suffix).srt"
    }
}

struct TranslatedVideoResultsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @State private var player: AVPlayer?
    @State private var exportError: String?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            header
            Divider()

            if let translated = workspace.translatedVideo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top, spacing: 22) {
                            ZStack {
                                Color.black
                                if let player {
                                    VideoPlayer(player: player)
                                }
                            }
                            .aspectRatio(translated.aspectMode == .vertical ? 9.0 / 16.0 : 16.0 / 9.0,
                                         contentMode: .fit)
                            .frame(maxWidth: 620, maxHeight: 620)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            details(translated)
                                .frame(width: 330, alignment: .topLeading)
                        }

                        Toggle(isOn: $settings.suggestHighlightPublishingCopy) {
                            Label("Suggest captions and hashtags", systemImage: "number")
                                .font(.headline)
                        }
                        .toggleStyle(.switch)

                        if settings.suggestHighlightPublishingCopy {
                            publishingCopyPanel(translated)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    let p = AVPlayer(url: translated.url)
                    p.play()
                    player = p
                }
                .onDisappear { player?.pause() }
            } else {
                ContentUnavailableView("No translated video", systemImage: "video.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
    }

    @ViewBuilder
    private func publishingCopyPanel(_ translated: TranslatedVideo) -> some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Publishing copy")
                        .font(.subheadline.weight(.semibold))
                    Text("Editable captions and hashtags for this subtitled video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.isGeneratingHighlightCopy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await workspace.generateTranslatedPublishingCopy(settings: settings) }
                    } label: {
                        Label(workspace.translatedVariants.isEmpty ? "Generate" : "Regenerate",
                              systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.mimoAPIKey.trimmed.isEmpty)
                    .help(settings.mimoAPIKey.trimmed.isEmpty
                          ? "Add a MiMo API key in Settings first."
                          : "Generate caption and hashtag suggestions")
                }
            }

            if let error = workspace.highlightCopyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if settings.mimoAPIKey.trimmed.isEmpty {
                Label("Add a MiMo API key in Settings to generate captions and hashtags.",
                      systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !workspace.translatedVariants.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    ForEach($workspace.translatedVariants) { $variant in
                        PostPreviewCard(variant: $variant, videoURL: translated.url)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text("Vietnamese subtitle translation")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let job = workspace.job {
                    Text(job.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                workspace.startOver()
            } label: {
                Label("Start over", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func details(_ translated: TranslatedVideo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                statChip(translated.durationLabel, "clock")
                statChip("\(translated.renderedTranscript.segments.count) cues", "captions.bubble")
            }
            statChip(translated.aspectMode.displayName, "aspectratio")

            Divider()

            Text("Vietnamese subtitles are burned into the full source video. The subtitle download contains only the rendered Vietnamese cues.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statChip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private var footer: some View {
        HStack {
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()

            Button {
                runSubtitleSavePanel()
            } label: {
                Label("Download subtitles", systemImage: "captions.bubble")
                    .frame(minWidth: 170)
            }
            .controlSize(.large)
            .disabled(workspace.translatedVideo?.renderedSRT() == nil)

            Button {
                runSavePanel()
            } label: {
                Label("Download video", systemImage: "arrow.down.circle.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(workspace.translatedVideo == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func runSavePanel() {
        guard let translated = workspace.translatedVideo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedFileName()
        panel.canCreateDirectories = true
        panel.title = "Download translated video"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: translated.url, to: destination)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func runSubtitleSavePanel() {
        guard let translated = workspace.translatedVideo,
              let srt = translated.renderedSRT()
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = suggestedSubtitleFileName()
        panel.canCreateDirectories = true
        panel.title = "Download rendered subtitles"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try srt.write(to: destination, atomically: true, encoding: .utf8)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func suggestedFileName() -> String {
        "\(suggestedBaseName())-vi-subtitled.mp4"
    }

    private func suggestedSubtitleFileName() -> String {
        "\(suggestedBaseName())-vi-rendered.srt"
    }

    private func suggestedBaseName() -> String {
        let source = workspace.job?.fileName ?? "translated-video"
        let base = source
            .replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "translated-video" : String(base.prefix(48))
    }
}
