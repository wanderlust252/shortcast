import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubtitleReviewView: View {

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppSettings.self) private var settings

    @State private var player: AVPlayer?
    @State private var selectedIndex: Int?
    @State private var exportError: String?
    @State private var isRendering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let review = workspace.pendingSubtitleReview {
                HStack(spacing: 0) {
                    cueList(review)
                        .frame(minWidth: 520)

                    Divider()

                    preview(review)
                        .frame(width: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: review.sourceURL) {
                    let p = AVPlayer(url: review.sourceURL)
                    player = p
                    if selectedIndex == nil {
                        selectedIndex = review.reviewIndices.first
                    }
                    seekToSelectedCue(in: review)
                }
                .onDisappear { player?.pause() }
                .onChange(of: selectedIndex) { _, _ in seekToSelectedCue(in: review) }
            } else {
                ContentUnavailableView("No subtitles to review", systemImage: "captions.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.pendingSubtitleReview?.mode.displayName ?? "Review subtitles")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let review = workspace.pendingSubtitleReview {
                    Text("\(review.sourceFileName)  ·  \(review.cueCount)/\(review.totalCueCount) cues selected")
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

    private func cueList(_ review: PendingSubtitleReview) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(review.reviewIndices, id: \.self) { index in
                        cueRow(review, index: index)
                            .id(index)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: selectedIndex) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func cueRow(_ review: PendingSubtitleReview, index: Int) -> some View {
        let rendered = review.renderedTranscript.segments[index]
        let source = review.sourceSegment(at: index) ?? rendered
        let isSelected = selectedIndex == index
        let isIncluded = !review.excludedCueIndices.contains(index)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { !review.excludedCueIndices.contains(index) },
                    set: { workspace.setPendingSubtitleCueIncluded(index: index, included: $0) })
                ) {
                    Text("Include in render")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(isSelected ? .white : .primary)

                Text(timeRangeLabel(rendered))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                if !isIncluded {
                    Text("Skipped")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                }
                Spacer()
                if SubtitleFormatter.needsRepair(rendered.text) {
                    Label("Long", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Source")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                Text(source.text)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Rendered subtitle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                TextEditor(text: binding(for: index))
                    .font(.body)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(minHeight: 58)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(isSelected ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(.quinary),
                                in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!isIncluded)
            }

            HStack(spacing: 8) {
                Button {
                    workspace.setPendingSubtitleCueIncluded(
                        index: index,
                        included: !isIncluded)
                } label: {
                    Label(isIncluded ? "Skip this cue" : "Use this cue",
                          systemImage: isIncluded ? "minus.circle" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
            }
            .font(.caption)
        }
        .padding(10)
        .opacity(isIncluded ? 1 : 0.48)
        .background(isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedIndex = index }
    }

    private func preview(_ review: PendingSubtitleReview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Color.black
                    if let player {
                        VideoPlayer(player: player)
                    }
                }
                .aspectRatio(review.aspectMode == .vertical ? 9.0 / 16.0 : 16.0 / 9.0,
                             contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let cue = selectedCue(in: review) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(timeRangeLabel(cue))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(SubtitleFormatter.displayText(cue.text))
                            .font(.system(size: 18, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        Text(cue.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Select a cue to preview it against the source video.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !workspace.reviewRenderOutputs.isEmpty {
                    Divider()
                    outputList(workspace.reviewRenderOutputs)
                }

                if review.mode == .fullVideo, let translated = workspace.translatedVideo {
                    Divider()
                    Toggle(isOn: Binding(
                        get: { settings.suggestHighlightPublishingCopy },
                        set: { settings.suggestHighlightPublishingCopy = $0 })
                    ) {
                        Label("Suggest captions and hashtags", systemImage: "number")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)

                    if settings.suggestHighlightPublishingCopy {
                        reviewPublishingCopyPanel(translated)
                    }
                }
            }
            .padding(22)
        }
        .scrollIndicators(.visible)
    }

    private var footer: some View {
        HStack {
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let error = workspace.pipelineError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let review = workspace.pendingSubtitleReview {
                HStack(spacing: 8) {
                    if review.cueCount > 0 {
                        Button {
                            workspace.deselectAllPendingSubtitleCues()
                        } label: {
                            Label("Deselect all", systemImage: "checklist.unchecked")
                        }
                        .controlSize(.large)
                        .disabled(isRendering)
                    }

                    if review.excludedCueCount > 0 {
                        Button {
                            workspace.restoreAllPendingSubtitleCues()
                        } label: {
                            Label("Select all", systemImage: "checklist.checked")
                        }
                        .controlSize(.large)
                        .disabled(isRendering)
                    }
                }
            }

            Spacer()

            Button {
                runSubtitleSavePanel()
            } label: {
                Label("Download subtitles", systemImage: "captions.bubble")
                    .frame(minWidth: 170)
            }
            .controlSize(.large)
            .disabled(workspace.pendingSubtitleReview?.renderedSRT() == nil || isRendering)

            Button {
                Task {
                    isRendering = true
                    await workspace.approveSubtitleReviewAndRender(settings: settings)
                    isRendering = false
                }
            } label: {
                Label(isRendering ? "Rendering…" : renderButtonTitle,
                      systemImage: "checkmark.circle.fill")
                    .frame(minWidth: 210)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled((workspace.pendingSubtitleReview?.cueCount ?? 0) == 0 || isRendering)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var renderButtonTitle: String {
        guard let review = workspace.pendingSubtitleReview else { return "Render" }
        if review.hasCustomSelection {
            return review.mode == .fullVideo ? "Render selected clips" : "Render selected cut"
        }
        return review.mode == .fullVideo ? "Render full video" : "Render highlight"
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding {
            workspace.pendingSubtitleReview?.renderedTranscript.segments[safe: index]?.text ?? ""
        } set: { newValue in
            workspace.updatePendingSubtitleText(index: index, text: newValue)
        }
    }

    private func selectedCue(in review: PendingSubtitleReview) -> TranscriptSegment? {
        guard let selectedIndex,
              review.renderedTranscript.segments.indices.contains(selectedIndex)
        else { return nil }
        return review.renderedTranscript.segments[selectedIndex]
    }

    private func seekToSelectedCue(in review: PendingSubtitleReview) {
        guard let player, let cue = selectedCue(in: review) else { return }
        player.pause()
        player.seek(to: CMTime(seconds: cue.start, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    private func runSubtitleSavePanel() {
        guard let review = workspace.pendingSubtitleReview,
              let srt = review.renderedSRT()
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = suggestedSubtitleFileName(for: review)
        panel.canCreateDirectories = true
        panel.title = "Download reviewed subtitles"
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

    private func outputList(_ outputs: [ReviewRenderOutput]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rendered outputs")
                .font(.headline)
            ForEach(outputs) { output in
                HStack(spacing: 10) {
                    Image(systemName: output.kind == .translatedShort ? "scissors" : "film")
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.title.isEmpty ? output.kind.displayName : output.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("\(output.kind.displayName) · \(output.durationLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        runOutputSavePanel(output)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func reviewPublishingCopyPanel(_ translated: TranslatedVideo) -> some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Publishing copy")
                    .font(.subheadline.weight(.semibold))
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
                }
            }

            if let error = workspace.highlightCopyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if settings.mimoAPIKey.trimmed.isEmpty {
                Label("Add a MiMo API key in Settings first.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !workspace.translatedVariants.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($workspace.translatedVariants) { $variant in
                        compactVariantEditor($variant)
                    }
                }
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func compactVariantEditor(_ variant: Binding<PostVariant>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: variant.wrappedValue.platform.symbolName)
                Text(variant.wrappedValue.platform.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(variant.wrappedValue.platform.tint)

            labeledEditor("Hook", text: variant.hook, minHeight: 36, maxHeight: 58)
            labeledEditor("Caption", text: variant.summary, minHeight: 74, maxHeight: 130)
            labeledEditor("Hashtags", text: hashtagsBinding(for: variant), minHeight: 58, maxHeight: 110)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func labeledEditor(
        _ title: String,
        text: Binding<String>,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.caption)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }

    private func hashtagsBinding(for variant: Binding<PostVariant>) -> Binding<String> {
        Binding {
            variant.wrappedValue.hashtags.map { "#\($0)" }.joined(separator: " ")
        } set: { newValue in
            variant.wrappedValue.hashtags = newValue
                .split(whereSeparator: { " ,\n".contains($0) })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                .filter { !$0.isEmpty }
        }
    }

    private func runOutputSavePanel(_ output: ReviewRenderOutput) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedOutputFileName(output)
        panel.canCreateDirectories = true
        panel.title = "Download rendered video"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: output.url, to: destination)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func suggestedOutputFileName(_ output: ReviewRenderOutput) -> String {
        let base = output.title
            .lowercased()
            .replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = output.kind == .translatedShort ? "short" : "subtitled"
        return "\((base.isEmpty ? "shortcast" : String(base.prefix(42))))-\(suffix).mp4"
    }

    private func suggestedSubtitleFileName(for review: PendingSubtitleReview) -> String {
        let base = review.sourceFileName
            .replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = review.mode == .highlight ? "highlight-reviewed" : "vi-reviewed"
        return "\((base.isEmpty ? "subtitles" : String(base.prefix(42))))-\(suffix).srt"
    }

    private func timeRangeLabel(_ segment: TranscriptSegment) -> String {
        "\(timeLabel(segment.start)) - \(timeLabel(segment.end))"
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
