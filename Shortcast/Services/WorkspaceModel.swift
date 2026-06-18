import Foundation
import Observation

/// Drives the main window's state machine. Three flows share it:
///  - short video → one set of editable legacy summaries.
///  - long video → transcribe/analyze → plan + render one K-pop montage.
///  - long video → transcribe → translate + render full subtitled video.
@MainActor
@Observable
final class WorkspaceModel {

    /// What the user wants to do with a dropped video. Chosen explicitly on the
    /// drop screen rather than guessed from the video's length.
    enum InputMode: String, CaseIterable, Identifiable, Sendable {
        case shorts    // long video → render one K-pop performance montage
        case translateFullVideo // long video → render full video with Vietnamese subtitles
        case caption   // short video → legacy captions and hashtag suggestions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .caption: "Caption a short"
            case .shorts:  "Make K-pop montage"
            case .translateFullVideo: "Translate full video"
            }
        }

        var dropTitle: String {
            switch self {
            case .caption: "Drop a short clip here"
            case .shorts:  "Drop a K-pop performance video here"
            case .translateFullVideo: "Drop a video to translate here"
            }
        }

        var dropSubtitle: String {
            switch self {
            case .caption: "Up to 60 seconds — suggest captions and hashtags"
            case .shorts:  "We'll find the chorus, dance breaks and camera-impact moments"
            case .translateFullVideo: "Render the whole video with Vietnamese subtitles"
            }
        }

        var symbol: String {
            switch self {
            case .caption: "film.stack"
            case .shorts:  "sparkles.tv"
            case .translateFullVideo: "captions.bubble"
            }
        }
    }

    /// The selected mode. Drives routing in `process(url:)`. Defaults to making
    /// a highlight from a long video — the app's headline flow.
    var inputMode: InputMode = .shorts {
        didSet {
            if inputMode == .caption {
                externalAudioURL = nil
            }
        }
    }

    enum Phase: Equatable {
        case empty
        // Single-video flow:
        case processing
        case results
        // Long-video highlight flow:
        case transcribing
        case findingMoments
        case translatingSubtitles
        case reviewingSubtitles
        case renderingHighlight
        case highlightResults
        case renderingTranslatedVideo
        case translatedVideoResults
        case shortsResults
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?
    private(set) var externalAudioURL: URL?

    var canUseExternalAudio: Bool {
        inputMode == .shorts || inputMode == .translateFullVideo
    }

    var externalAudioFileName: String? {
        externalAudioURL?.lastPathComponent
    }

    /// The three proposed posts (single-video flow). Bound by the result cards.
    var variants: [PostVariant] = []
    private(set) var detectedLanguage: String?

    /// Legacy generated shorts state, still used by the older per-clip helpers.
    var clips: [ShortClip] = []

    /// The rendered long-video highlight.
    var highlightVideo: HighlightVideo?

    /// Optional post-render caption/hashtag suggestions for the rendered highlight.
    var highlightVariants: [PostVariant] = []
    var translatedVariants: [PostVariant] = []
    private(set) var isGeneratingHighlightCopy = false
    private(set) var highlightCopyError: String?

    /// The rendered full-length Vietnamese subtitle translation.
    var translatedVideo: TranslatedVideo?

    /// Translated/proofread subtitles waiting for manual approval before render.
    var pendingSubtitleReview: PendingSubtitleReview?
    var reviewRenderOutputs: [ReviewRenderOutput] = []

    /// Owns transcription (sidecar `.srt`/`.vtt` or on-device WhisperKit).
    let transcription = TranscriptionService()

    /// Non-fatal banner shown on the drop screen.
    var errorMessage: String?
    /// Fatal pipeline error (transcription / moment-finding failed).
    private(set) var pipelineError: String?

    private var pipelineTask: Task<Void, Never>?

    // Publishing (legacy single-video flow)
    private(set) var isPublishing = false
    private(set) var publishReport: PublishReport?
    private(set) var publishError: String?
    /// True while "Publish all approved" runs over the shorts.
    private(set) var isPublishingAll = false

    var isBusy: Bool {
        switch phase {
        case .processing, .transcribing, .findingMoments, .renderingHighlight: return true
        case .translatingSubtitles, .renderingTranslatedVideo: return true
        default: return false
        }
    }

    // MARK: - Entry

    /// Validates a dropped file and routes to the right flow based on length.
    func process(url: URL, modelManager: ModelManager, settings: AppSettings) async {
        errorMessage = nil
        publishReport = nil
        publishError = nil
        pipelineError = nil

        let newJob: VideoJob
        do {
            newJob = try await MediaExtractor.makeJob(from: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        switch inputMode {
        case .caption:
            await processSingleVideo(job: newJob, modelManager: modelManager, settings: settings)
        case .shorts:
            startShortsPipeline(
                job: newJob,
                audioURL: externalAudioURL,
                modelManager: modelManager,
                settings: settings)
        case .translateFullVideo:
            startTranslationPipeline(
                job: newJob,
                audioURL: externalAudioURL,
                settings: settings)
        }
    }

    func attachExternalAudio(url: URL) async {
        guard canUseExternalAudio else { return }
        errorMessage = nil
        do {
            try await MediaExtractor.validateAudioFile(url)
            externalAudioURL = url
        } catch {
            externalAudioURL = nil
            errorMessage = "Couldn't use that audio file. \(error.localizedDescription)"
        }
    }

    func removeExternalAudio() {
        externalAudioURL = nil
        if errorMessage?.localizedCaseInsensitiveContains("audio") == true {
            errorMessage = nil
        }
    }

    // MARK: - Legacy single-video summary flow

    private func processSingleVideo(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        job = newJob
        variants = []
        detectedLanguage = nil
        phase = .processing

        do {
            if modelManager.engine == nil {
                await modelManager.prepareIfNeeded()
            }
            guard let engine = modelManager.engine else {
                throw MomentFinderError.notReady
            }
            let result = try await GemmaService.generate(
                job: newJob,
                engine: engine,
                languageOverride: settings.languageOverride,
                styleExamples: settings.styleExamples)
            variants = result.variants
            detectedLanguage = result.detectedLanguage
            phase = .results
        } catch {
            errorMessage = "Couldn't generate captions for that video. \(error.localizedDescription)"
            job = nil
            phase = .empty
        }
    }

    // MARK: - Shorts flow

    private func startShortsPipeline(
        job newJob: VideoJob,
        audioURL: URL?,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        cleanupClipTempFiles()
        cleanupHighlightTempFile()
        cleanupTranslatedTempFile()
        cleanupReviewOutputTempFiles()
        job = newJob
        clips = []
        highlightVideo = nil
        highlightVariants = []
        translatedVariants = []
        highlightCopyError = nil
        translatedVideo = nil
        pendingSubtitleReview = nil
        reviewRenderOutputs = []
        variants = []
        pipelineError = nil
        phase = .transcribing

        pipelineTask = Task {
            await self.runShortsPipeline(
                job: newJob,
                audioURL: audioURL,
                modelManager: modelManager,
                settings: settings)
        }
    }

    private func runShortsPipeline(
        job: VideoJob,
        audioURL: URL?,
        modelManager: ModelManager,
        settings: AppSettings
    ) async {
        let pipelineStart = Date()
        Self.log("pipeline start — copywriter=\(settings.copywriterModel.rawValue)")
        do {
            // 1. Transcript: sidecar .srt/.vtt if present, else WhisperKit.
            phase = .transcribing
            let t0 = Date()
            let mimo = MimoService(
                apiKey: settings.mimoAPIKey,
                modelID: settings.mimoModelID,
                baseURL: settings.mimoBaseURL)
            let transcript = try await transcription.transcript(
                for: job.url,
                audioOverrideURL: audioURL,
                languageHint: settings.languageOverride,
                backend: settings.transcriptionBackend,
                mimo: mimo)
            // Trust the language of the actual text over Whisper's 30s auto-detect.
            let captionLanguage = transcript.contentLanguage ?? transcript.language
            let outputLanguage = settings.languageOverride.trimmed.isEmpty
                ? captionLanguage
                : settings.languageOverride
            Self.log("transcript ready in \(Self.elapsed(since: t0)) — whisper=\(transcript.language ?? "?"), text=\(captionLanguage ?? "?"), output=\(outputLanguage ?? "?")")
            try Task.checkCancellation()

            // 2. Score local K-pop performance signals, then plan the montage with MiMo.
            phase = .findingMoments
            let t1 = Date()
            let kpopAnalysis = await KpopSignalAnalyzer.analyze(
                videoURL: job.url,
                transcript: transcript,
                sourceDuration: job.durationSeconds)
            Self.log("kpop analysis ready — \(kpopAnalysis.candidates.count) candidate(s)")
            Self.log("director selected — MiMo API (\(settings.mimoModelID.trimmed.isEmpty ? "mimo-v2.5-pro" : settings.mimoModelID.trimmed))")
            let plan = try await mimo.planHighlight(
                transcript: transcript.srtLike(),
                language: outputLanguage,
                sourceDuration: job.durationSeconds,
                kpopAnalysis: kpopAnalysis)
            Self.log("highlight plan ready in \(Self.elapsed(since: t1)) — \(plan.segments.count) segment(s), \(Int(plan.duration.rounded()))s")
            try Task.checkCancellation()

            // 3. Render one montage video from the selected ranges.
            let t2 = Date()
            let renderTranscript = try await transcriptForHighlightSubtitles(
                transcript,
                plan: plan,
                settings: settings,
                mimo: mimo)
            if settings.reviewSubtitlesBeforeRender && settings.highlightSubtitleLanguage.targetLanguage != nil {
                let reviewSourceTranscript = transcript.clipped(to: plan.segments)
                let reviewRenderedTranscript = renderTranscript.clipped(to: plan.segments)
                pendingSubtitleReview = PendingSubtitleReview(
                    mode: .highlight,
                    sourceURL: job.url,
                    sourceFileName: job.fileName,
                    sourceDurationSeconds: job.durationSeconds,
                    plan: plan,
                    sourceTranscript: reviewSourceTranscript,
                    renderedTranscript: reviewRenderedTranscript,
                    aspectMode: settings.highlightAspectMode,
                    showIntroCard: settings.showHighlightIntroCard,
                    exportQuality: settings.exportQualityMode)
                phase = .reviewingSubtitles
                Self.log("highlight subtitles ready for review — cues=\(pendingSubtitleReview?.cueCount ?? 0)")
                return
            }
            phase = .renderingHighlight
            Self.log("render highlight — aspect=\(settings.highlightAspectMode.rawValue), subtitles=\(settings.highlightSubtitleLanguage.rawValue), quality=\(settings.exportQualityMode.rawValue)")
            highlightVideo = try await renderHighlightVideo(
                sourceURL: job.url,
                plan: plan,
                sourceTranscript: transcript,
                renderedTranscript: renderTranscript,
                aspectMode: settings.highlightAspectMode,
                showIntroCard: settings.showHighlightIntroCard,
                subtitleHeight: settings.subtitleHeight,
                exportQuality: settings.exportQualityMode)
            phase = .highlightResults
            Self.log("highlight rendered in \(Self.elapsed(since: t2)); pipeline done in \(Self.elapsed(since: pipelineStart)) total")
        } catch is CancellationError {
            cleanupClipTempFiles()
            cleanupHighlightTempFile()
            clips = []
            highlightVideo = nil
            highlightVariants = []
            translatedVariants = []
            highlightCopyError = nil
            translatedVideo = nil
            pendingSubtitleReview = nil
            reviewRenderOutputs = []
            self.job = nil
            phase = .empty
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't make a K-pop montage from that video. \(error.localizedDescription)"
            self.job = nil
            clips = []
            highlightVideo = nil
            highlightVariants = []
            translatedVariants = []
            highlightCopyError = nil
            translatedVideo = nil
            pendingSubtitleReview = nil
            reviewRenderOutputs = []
            phase = .empty
        }
    }

    // MARK: - Full-video translation flow

    private func startTranslationPipeline(job newJob: VideoJob, audioURL: URL?, settings: AppSettings) {
        cleanupClipTempFiles()
        cleanupHighlightTempFile()
        cleanupTranslatedTempFile()
        cleanupReviewOutputTempFiles()
        job = newJob
        clips = []
        highlightVideo = nil
        highlightVariants = []
        translatedVariants = []
        highlightCopyError = nil
        translatedVideo = nil
        pendingSubtitleReview = nil
        reviewRenderOutputs = []
        variants = []
        pipelineError = nil
        phase = .transcribing

        pipelineTask = Task {
            await self.runTranslationPipeline(job: newJob, audioURL: audioURL, settings: settings)
        }
    }

    private func runTranslationPipeline(job: VideoJob, audioURL: URL?, settings: AppSettings) async {
        let pipelineStart = Date()
        Self.log("translation pipeline start")
        do {
            phase = .transcribing
            let mimo = MimoService(
                apiKey: settings.mimoAPIKey,
                modelID: settings.mimoModelID,
                baseURL: settings.mimoBaseURL)
            let transcript = try await transcription.transcript(
                for: job.url,
                audioOverrideURL: audioURL,
                languageHint: settings.languageOverride,
                backend: settings.transcriptionBackend,
                mimo: mimo)
            let transcriptLanguage = transcript.contentLanguage ?? transcript.language
            Self.log("translation transcript ready — whisper=\(transcript.language ?? "?"), text=\(transcriptLanguage ?? "?")")
            try Task.checkCancellation()

            phase = .translatingSubtitles
            let renderedTranscript = try await transcriptForFullVideoTranslation(
                transcript,
                settings: settings,
                mimo: mimo)
            Self.log("translated full-video subtitles — cues=\(renderedTranscript.segments.count)")
            try Task.checkCancellation()

            if settings.reviewSubtitlesBeforeRender {
                pendingSubtitleReview = PendingSubtitleReview(
                    mode: .fullVideo,
                    sourceURL: job.url,
                    sourceFileName: job.fileName,
                    sourceDurationSeconds: job.durationSeconds,
                    plan: nil,
                    sourceTranscript: transcript,
                    renderedTranscript: renderedTranscript,
                    aspectMode: settings.highlightAspectMode,
                    showIntroCard: false,
                    exportQuality: settings.exportQualityMode)
                phase = .reviewingSubtitles
                Self.log("full-video subtitles ready for review — cues=\(pendingSubtitleReview?.cueCount ?? 0)")
                return
            }

            phase = .renderingTranslatedVideo
            Self.log("render translated video — aspect=\(settings.highlightAspectMode.rawValue), quality=\(settings.exportQualityMode.rawValue)")
            translatedVideo = try await renderTranslatedVideo(
                sourceURL: job.url,
                renderedTranscript: renderedTranscript,
                durationSeconds: job.durationSeconds,
                aspectMode: settings.highlightAspectMode,
                subtitleHeight: settings.subtitleHeight,
                exportQuality: settings.exportQualityMode)
            phase = .translatedVideoResults
            Self.log("translated video rendered; pipeline done in \(Self.elapsed(since: pipelineStart)) total")
        } catch is CancellationError {
            cleanupClipTempFiles()
            cleanupHighlightTempFile()
            cleanupTranslatedTempFile()
            clips = []
            highlightVideo = nil
            highlightVariants = []
            translatedVariants = []
            highlightCopyError = nil
            translatedVideo = nil
            pendingSubtitleReview = nil
            reviewRenderOutputs = []
            self.job = nil
            phase = .empty
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't translate that video. \(error.localizedDescription)"
            self.job = nil
            clips = []
            highlightVideo = nil
            highlightVariants = []
            translatedVariants = []
            highlightCopyError = nil
            translatedVideo = nil
            pendingSubtitleReview = nil
            reviewRenderOutputs = []
            phase = .empty
        }
    }

    func updatePendingSubtitleText(index: Int, text: String) {
        pendingSubtitleReview?.updateRenderedText(at: index, text: text)
    }

    func setPendingSubtitleCueIncluded(index: Int, included: Bool) {
        pendingSubtitleReview?.setCueIncluded(at: index, included: included)
    }

    func restoreAllPendingSubtitleCues() {
        pendingSubtitleReview?.restoreAllCues()
    }

    func deselectAllPendingSubtitleCues() {
        pendingSubtitleReview?.deselectAllCues()
    }

    func approveSubtitleReviewAndRender(settings: AppSettings) async {
        guard let review = pendingSubtitleReview else { return }
        pipelineError = nil
        errorMessage = nil

        do {
            switch review.mode {
            case .highlight:
                guard let plan = review.hasCustomSelection
                        ? review.selectionPlan(title: review.plan?.title)
                        : review.plan
                else { throw SubtitleReviewError.missingHighlightPlan }
                phase = .renderingHighlight
                let video = try await renderHighlightVideo(
                    sourceURL: review.sourceURL,
                    plan: plan,
                    sourceTranscript: review.hasCustomSelection ? review.filteredSourceTranscript() : review.sourceTranscript,
                    renderedTranscript: review.hasCustomSelection ? review.filteredRenderedTranscript() : review.renderedTranscript,
                    aspectMode: review.aspectMode,
                    showIntroCard: review.hasCustomSelection ? false : review.showIntroCard,
                    subtitleHeight: settings.subtitleHeight,
                    exportQuality: review.exportQuality)
                highlightVideo = video
                highlightVariants = []
                highlightCopyError = nil
                reviewRenderOutputs.insert(
                    ReviewRenderOutput(
                        kind: .highlight,
                        url: video.url,
                        title: video.plan.title,
                        durationSeconds: video.durationSeconds,
                        aspectMode: video.aspectMode,
                        renderedTranscript: review.hasCustomSelection
                            ? outputTimelineTranscript(for: plan, transcript: review.filteredRenderedTranscript(), showIntroCard: false)
                            : outputTimelineTranscript(for: plan, transcript: review.renderedTranscript, showIntroCard: review.showIntroCard)),
                    at: 0)
                phase = .reviewingSubtitles
            case .fullVideo:
                if review.hasCustomSelection {
                    guard let plan = review.selectionPlan() else { throw MomentFinderError.noClips }
                    phase = .renderingHighlight
                    let video = try await renderHighlightVideo(
                        sourceURL: review.sourceURL,
                        plan: plan,
                        sourceTranscript: review.filteredSourceTranscript(),
                        renderedTranscript: review.filteredRenderedTranscript(),
                        aspectMode: review.aspectMode,
                        showIntroCard: false,
                        subtitleHeight: settings.subtitleHeight,
                        exportQuality: review.exportQuality)
                    let outputTranscript = outputTimelineTranscript(
                        for: plan,
                        transcript: review.filteredRenderedTranscript(),
                        showIntroCard: false)
                    translatedVideo = TranslatedVideo(
                        url: video.url,
                        renderedTranscript: outputTranscript,
                        durationSeconds: video.durationSeconds,
                        aspectMode: video.aspectMode)
                    reviewRenderOutputs.insert(
                        ReviewRenderOutput(
                            kind: .translatedShort,
                            url: video.url,
                            title: plan.title,
                            durationSeconds: video.durationSeconds,
                            aspectMode: video.aspectMode,
                            renderedTranscript: outputTranscript),
                        at: 0)
                } else {
                    phase = .renderingTranslatedVideo
                    let video = try await renderTranslatedVideo(
                        sourceURL: review.sourceURL,
                        renderedTranscript: review.renderedTranscript,
                        durationSeconds: review.sourceDurationSeconds,
                        aspectMode: review.aspectMode,
                        subtitleHeight: settings.subtitleHeight,
                        exportQuality: review.exportQuality)
                    translatedVideo = video
                    reviewRenderOutputs.insert(
                        ReviewRenderOutput(
                            kind: .translatedFullVideo,
                            url: video.url,
                            title: review.sourceFileName,
                            durationSeconds: video.durationSeconds,
                            aspectMode: video.aspectMode,
                            renderedTranscript: video.renderedTranscript),
                        at: 0)
                }
                translatedVariants = []
                highlightCopyError = nil
                phase = .reviewingSubtitles
            }
        } catch is CancellationError {
            phase = .reviewingSubtitles
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't render the approved subtitles. \(error.localizedDescription)"
            phase = .reviewingSubtitles
        }
    }

    private func renderHighlightVideo(
        sourceURL: URL,
        plan: HighlightPlan,
        sourceTranscript: Transcript,
        renderedTranscript: Transcript,
        aspectMode: HighlightAspectMode,
        showIntroCard: Bool,
        subtitleHeight: Double,
        exportQuality: ExportQualityMode
    ) async throws -> HighlightVideo {
        let outputURL = try await MediaExtractor.renderHighlight(
            from: sourceURL,
            plan: plan,
            transcript: renderedTranscript,
            aspectMode: aspectMode,
            showIntroCard: showIntroCard,
            subtitleHeight: subtitleHeight,
            exportQuality: exportQuality)
        let durationSeconds = showIntroCard
            ? plan.duration
            : plan.segments.reduce(0) { $0 + $1.duration }
        return HighlightVideo(
            plan: plan,
            url: outputURL,
            aspectMode: aspectMode,
            showIntroCard: showIntroCard,
            sourceTranscript: sourceTranscript,
            renderedTranscript: renderedTranscript,
            durationSeconds: durationSeconds)
    }

    private func renderTranslatedVideo(
        sourceURL: URL,
        renderedTranscript: Transcript,
        durationSeconds: Double,
        aspectMode: HighlightAspectMode,
        subtitleHeight: Double,
        exportQuality: ExportQualityMode
    ) async throws -> TranslatedVideo {
        let outputURL = try await MediaExtractor.renderSubtitledFullVideo(
            from: sourceURL,
            transcript: renderedTranscript,
            aspectMode: aspectMode,
            subtitleHeight: subtitleHeight,
            exportQuality: exportQuality)
        return TranslatedVideo(
            url: outputURL,
            renderedTranscript: renderedTranscript,
            durationSeconds: durationSeconds,
            aspectMode: aspectMode)
    }

    func generateHighlightPublishingCopy(settings: AppSettings) async {
        guard let highlightVideo, !isGeneratingHighlightCopy else { return }
        highlightCopyError = nil
        isGeneratingHighlightCopy = true
        defer { isGeneratingHighlightCopy = false }

        do {
            let mimo = MimoService(
                apiKey: settings.mimoAPIKey,
                modelID: settings.mimoModelID,
                baseURL: settings.mimoBaseURL)
            let transcriptContext = highlightPublishingTranscriptContext(highlightVideo)
            let result = try await mimo.captionHighlight(
                plan: highlightVideo.plan,
                transcriptContext: transcriptContext,
                languageOverride: settings.languageOverride,
                styleExamples: settings.styleExamples)
            highlightVariants = result.variants
        } catch {
            highlightCopyError = error.localizedDescription
        }
    }

    func generateTranslatedPublishingCopy(settings: AppSettings) async {
        guard let translatedVideo, !isGeneratingHighlightCopy else { return }
        highlightCopyError = nil
        isGeneratingHighlightCopy = true
        defer { isGeneratingHighlightCopy = false }

        do {
            let title = job?.fileName.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
                ?? "Translated video"
            let plan = HighlightPlan(
                title: title,
                summary: "Subtitled video generated from the source.",
                segments: [
                    HighlightSegment(
                        start: 0,
                        end: translatedVideo.durationSeconds,
                        title: title,
                        why: "")
                ])
            let transcriptContext = translatedVideo.renderedTranscript.segments
                .map(\.text)
                .map(\.trimmed)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let mimo = MimoService(
                apiKey: settings.mimoAPIKey,
                modelID: settings.mimoModelID,
                baseURL: settings.mimoBaseURL)
            let result = try await mimo.captionHighlight(
                plan: plan,
                transcriptContext: transcriptContext,
                languageOverride: settings.languageOverride,
                styleExamples: settings.styleExamples)
            translatedVariants = result.variants
        } catch {
            highlightCopyError = error.localizedDescription
        }
    }

    private func transcriptForFullVideoTranslation(
        _ transcript: Transcript,
        settings: AppSettings,
        mimo: MimoService
    ) async throws -> Transcript {
        let targetLanguage = "Vietnamese"
        let transcriptLanguage = transcript.contentLanguage ?? transcript.language
        let context = SubtitleContextBuilder.makeFullVideoContext(
            transcript: transcript,
            targetLanguage: targetLanguage,
            sourceLanguage: transcriptLanguage)

        if TranscriptionService.languageCode(from: transcriptLanguage ?? "") == "vi" {
            Self.log("proofread Vietnamese full-video subtitles — cues=\(transcript.segments.count)")
            return try await mimo.proofreadVietnameseSubtitleSegments(transcript.segments, context: context)
                .translatedTranscript(language: "vi")
        }

        Self.log("translate full-video subtitles — target=\(targetLanguage), cues=\(transcript.segments.count)")
        return try await mimo.translateSubtitleSegments(transcript.segments, context: context)
            .translatedTranscript(language: "vi")
    }

    private func transcriptForHighlightSubtitles(
        _ transcript: Transcript,
        plan: HighlightPlan,
        settings: AppSettings,
        mimo: MimoService
    ) async throws -> Transcript {
        guard let targetLanguage = settings.highlightSubtitleLanguage.targetLanguage else {
            return transcript
        }
        let transcriptLanguage = transcript.contentLanguage ?? transcript.language
        let selectedIndices = transcript.segments.indices.filter { index in
            let cue = transcript.segments[index]
            return plan.segments.contains { segment in
                cue.end > segment.start && cue.start < segment.end
            }
        }
        guard !selectedIndices.isEmpty else { return transcript }

        if targetLanguage == "Vietnamese",
           TranscriptionService.languageCode(from: transcriptLanguage ?? "") == "vi" {
            Self.log("proofread Vietnamese highlight subtitles — cues=\(selectedIndices.count)")
            var proofreadByIndex: [Int: TranscriptSegment] = [:]
            for segment in plan.segments {
                let indices = transcript.segments.indices.filter { index in
                    let cue = transcript.segments[index]
                    return cue.end > segment.start && cue.start < segment.end
                }
                guard !indices.isEmpty else { continue }
                let selectedSegments = indices.map { transcript.segments[$0] }
                let context = SubtitleContextBuilder.makeContext(
                    transcript: transcript,
                    plan: plan,
                    segment: segment,
                    targetLanguage: targetLanguage,
                    sourceLanguage: transcriptLanguage)
                let proofread = try await mimo.proofreadVietnameseSubtitleSegments(
                    selectedSegments,
                    context: context)
                for (offset, index) in indices.enumerated() where offset < proofread.count {
                    proofreadByIndex[index] = proofread[offset]
                }
            }
            var output = transcript.segments
            for (index, proofread) in proofreadByIndex {
                output[index] = proofread
            }
            return Transcript(segments: output, language: "vi")
        }

        Self.log("translate highlight subtitles — target=\(targetLanguage), cues=\(selectedIndices.count)")
        var translatedByIndex: [Int: TranscriptSegment] = [:]
        for segment in plan.segments {
            let indices = transcript.segments.indices.filter { index in
                let cue = transcript.segments[index]
                return cue.end > segment.start && cue.start < segment.end
            }
            guard !indices.isEmpty else { continue }
            let selectedSegments = indices.map { transcript.segments[$0] }
            let context = SubtitleContextBuilder.makeContext(
                transcript: transcript,
                plan: plan,
                segment: segment,
                targetLanguage: targetLanguage,
                sourceLanguage: transcriptLanguage)
            let translated = try await mimo.translateSubtitleSegments(
                selectedSegments,
                context: context)
            for (offset, index) in indices.enumerated() where offset < translated.count {
                translatedByIndex[index] = translated[offset]
            }
        }
        var output = transcript.segments
        for (index, translated) in translatedByIndex {
            output[index] = translated
        }
        return Transcript(segments: output, language: "vi")
    }

    private func captionClip(_ clip: ShortClip, modelManager: ModelManager, settings: AppSettings,
                             transcriptLanguage: String?) async throws -> GenerationResult {
        // Lock the output language to what Whisper detected unless the user set a
        // manual override — small captioners otherwise drift (e.g. Spanish → pt-BR).
        let effectiveLanguage = settings.languageOverride.trimmed.isEmpty
            ? (transcriptLanguage ?? "")
            : settings.languageOverride

        switch settings.copywriterModel {
        case .gemmaE4B:
            guard let engine = modelManager.engine, let clipJob = clip.clipJob else {
                throw MomentFinderError.notReady
            }
            return try await GemmaService.generate(
                job: clipJob,
                engine: engine,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples)
        case .gemma12B, .qwen35_9b:
            // Inline-caption models normally write captions in the moment-finding
            // pass; this is the fallback per-clip path using the same Director.
            if let profile = settings.copywriterModel.directorProfile {
                await modelManager.prepareDirector(profile: profile)
            }
            return try await modelManager.momentFinder.caption(
                transcriptSlice: clip.transcriptSlice,
                hook: clip.candidate.hook,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples)
        case .mimo:
            let mimo = MimoService(
                apiKey: settings.mimoAPIKey,
                modelID: settings.mimoModelID,
                baseURL: settings.mimoBaseURL)
            return try await mimo.caption(
                transcriptSlice: clip.transcriptSlice,
                hook: clip.candidate.hook,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples)
        }
    }

    func cancelPipeline() {
        pipelineTask?.cancel()
    }

    // MARK: - Timing logs (stderr; visible when launched from the terminal)

    nonisolated static func log(_ message: String) {
        ShortcastTrace.log("pipeline", message)
    }

    /// Formatted seconds elapsed between two dates (defaults `to` = now).
    nonisolated static func elapsed(since start: Date, to end: Date = Date()) -> String {
        String(format: "%.1fs", end.timeIntervalSince(start))
    }

    // MARK: - Reset

    /// Returns to the empty drop state and cleans up temp files.
    func startOver() {
        pipelineTask?.cancel()
        cleanupClipTempFiles()
        cleanupHighlightTempFile()
        cleanupTranslatedTempFile()
        cleanupReviewOutputTempFiles()
        job = nil
        externalAudioURL = nil
        variants = []
        clips = []
        highlightVideo = nil
        highlightVariants = []
        translatedVariants = []
        highlightCopyError = nil
        translatedVideo = nil
        pendingSubtitleReview = nil
        reviewRenderOutputs = []
        detectedLanguage = nil
        publishReport = nil
        publishError = nil
        errorMessage = nil
        pipelineError = nil
        phase = .empty
    }

    private func cleanupClipTempFiles() {
        for clip in clips {
            if let url = clip.clipJob?.url {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func cleanupHighlightTempFile() {
        if let url = highlightVideo?.url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupTranslatedTempFile() {
        if let url = translatedVideo?.url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupReviewOutputTempFiles() {
        let preserved = Set([highlightVideo?.url, translatedVideo?.url].compactMap(\.self))
        for output in reviewRenderOutputs where !preserved.contains(output.url) {
            try? FileManager.default.removeItem(at: output.url)
        }
    }

    // MARK: - Publishing (single-video flow)

    func publish(settings: AppSettings) async {
        guard let job, !isPublishing else { return }
        publishError = nil
        publishReport = nil
        isPublishing = true
        defer { isPublishing = false }

        let provider = settings.activePublishingProvider
        let publishVariants = variants.filter { provider.supportedPlatforms.contains($0.platform) }
        do {
            publishReport = try await provider.publish(
                videoURL: job.url,
                variants: publishVariants,
                tiktokAsDraft: settings.tiktokAsDraft,
                scheduledDate: nil,
                settings: settings)
        } catch {
            publishError = error.localizedDescription
        }
    }

    func dismissPublishResult() {
        publishReport = nil
        publishError = nil
    }

    // MARK: - Publishing (shorts flow)

    var approvedReadyCount: Int {
        clips.filter { $0.isApproved && $0.isReadyToPublish }.count
    }

    /// Publishes every approved, ready clip in turn. Each clip keeps its own
    /// status, so a partial batch is reflected per card. Stops early if a clip
    /// hits the Upload-Post monthly limit.
    func publishAllApproved(settings: AppSettings) async {
        guard !isPublishingAll else { return }
        isPublishingAll = true
        defer { isPublishingAll = false }

        for clip in clips where clip.isApproved && clip.isReadyToPublish {
            await clip.publish(settings: settings)
            if let error = clip.publishError, error.localizedCaseInsensitiveContains("limit") {
                break
            }
        }
    }

    /// True while "Schedule all" runs.
    private(set) var isSchedulingAll = false

    /// The dates each approved, ready clip would be scheduled to: the first at
    /// `start`, then one every `intervalDays`. Used for the schedule preview.
    func schedulePlan(start: Date, intervalDays: Int) -> [(clip: ShortClip, date: Date)] {
        let cal = Calendar.current
        var date = start
        var plan: [(ShortClip, Date)] = []
        for clip in clips where clip.isApproved && clip.isReadyToPublish {
            plan.append((clip, date))
            date = cal.date(byAdding: .day, value: max(1, intervalDays), to: date) ?? date
        }
        return plan
    }

    /// Schedules every approved, ready clip: the first at `start`, then one every
    /// `intervalDays`. Sequential; stops cleanly on the monthly limit.
    func scheduleAllApproved(start: Date, intervalDays: Int, settings: AppSettings) async {
        guard !isSchedulingAll else { return }
        isSchedulingAll = true
        defer { isSchedulingAll = false }

        for (clip, date) in schedulePlan(start: start, intervalDays: intervalDays) {
            await clip.publish(settings: settings, scheduledDate: date)
            if let error = clip.publishError, error.localizedCaseInsensitiveContains("limit") {
                break
            }
        }
    }
}

private func highlightPublishingTranscriptContext(_ highlight: HighlightVideo) -> String {
    let transcript = highlight.renderedTranscript ?? highlight.sourceTranscript
    guard let transcript else {
        let segmentLines = highlight.plan.segments.map {
            "\($0.rangeLabel) \($0.title)\($0.why.isEmpty ? "" : ". \($0.why)")"
        }
        return ([highlight.plan.summary] + segmentLines)
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var lines: [String] = []
    for segment in highlight.plan.segments {
        let cues = transcript.segments.filter { cue in
            cue.end > segment.start && cue.start < segment.end
        }
        guard !cues.isEmpty else { continue }
        lines.append("[\(segment.rangeLabel)] \(segment.title)")
        for cue in cues {
            let text = cue.text.trimmed
            if !text.isEmpty {
                lines.append(text)
            }
        }
    }
    return lines.joined(separator: "\n")
}

private func outputTimelineTranscript(
    for plan: HighlightPlan,
    transcript: Transcript,
    showIntroCard: Bool
) -> Transcript {
    var output: [TranscriptSegment] = []
    var cursor = showIntroCard ? HighlightPlan.introDuration : 0
    for segment in plan.segments {
        for cue in transcript.segments where cue.end > segment.start && cue.start < segment.end {
            let sourceStart = max(cue.start, segment.start)
            let sourceEnd = min(cue.end, segment.end)
            guard sourceEnd - sourceStart >= 0.2 else { continue }
            output.append(TranscriptSegment(
                start: cursor + (sourceStart - segment.start),
                end: cursor + (sourceEnd - segment.start),
                text: cue.text,
                speakerID: cue.speakerID))
        }
        cursor += segment.duration
    }
    return Transcript(segments: output, language: transcript.language)
}

private extension Array where Element == TranscriptSegment {
    func translatedTranscript(language: String) -> Transcript {
        Transcript(segments: self, language: language)
    }
}

private enum SubtitleReviewError: LocalizedError {
    case missingHighlightPlan

    var errorDescription: String? {
        switch self {
        case .missingHighlightPlan:
            return "The reviewed highlight subtitles no longer have a highlight plan."
        }
    }
}
