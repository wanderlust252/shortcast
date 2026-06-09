import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HighlightResultsView: View {

    @Environment(WorkspaceModel.self) private var workspace
    @State private var player: AVPlayer?
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let highlight = workspace.highlightVideo {
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
                .padding(24)
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
                                Label("Output \(highlight.plan.outputRangeLabel(for: segment))",
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

    private func suggestedFileName(for highlight: HighlightVideo) -> String {
        let base = highlight.plan.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "highlight" : String(base.prefix(48))) + ".mp4"
    }
}
