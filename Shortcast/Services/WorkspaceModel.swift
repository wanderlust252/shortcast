import Foundation
import Observation

/// Drives the main window's state machine. Two flows share it:
///  - short video → one set of editable variants → publish (the original path).
///  - long video → transcribe → plan + render one highlight video.
@MainActor
@Observable
final class WorkspaceModel {

    /// What the user wants to do with a dropped video. Chosen explicitly on the
    /// drop screen rather than guessed from the video's length.
    enum InputMode: String, CaseIterable, Identifiable, Sendable {
        case shorts    // long video → render one educational highlight video
        case caption   // short video → captions → publish (the original flow)

        var id: String { rawValue }

        var title: String {
            switch self {
            case .caption: "Caption a short"
            case .shorts:  "Make highlight video"
            }
        }

        var dropTitle: String {
            switch self {
            case .caption: "Drop a short video here"
            case .shorts:  "Drop a lecture, podcast or interview here"
            }
        }

        var dropSubtitle: String {
            switch self {
            case .caption: "Up to 60 seconds — a TikTok, Reel or Short"
            case .shorts:  "We'll remove the rambling and render one 5-15 minute highlight"
            }
        }

        var symbol: String {
            switch self {
            case .caption: "film.stack"
            case .shorts:  "sparkles.tv"
            }
        }
    }

    /// The selected mode. Drives routing in `process(url:)`. Defaults to making
    /// a highlight from a long video — the app's headline flow.
    var inputMode: InputMode = .shorts

    enum Phase: Equatable {
        case empty
        // Single-video flow:
        case processing
        case results
        // Long-video highlight flow:
        case transcribing
        case findingMoments
        case renderingHighlight
        case highlightResults
        case shortsResults
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?

    /// The three proposed posts (single-video flow). Bound by the result cards.
    var variants: [PostVariant] = []
    private(set) var detectedLanguage: String?

    /// Legacy generated shorts state, still used by the older per-clip helpers.
    var clips: [ShortClip] = []

    /// The rendered long-video highlight.
    var highlightVideo: HighlightVideo?

    /// Owns transcription (sidecar `.srt`/`.vtt` or on-device WhisperKit).
    let transcription = TranscriptionService()

    /// Non-fatal banner shown on the drop screen.
    var errorMessage: String?
    /// Fatal pipeline error (transcription / moment-finding failed).
    private(set) var pipelineError: String?

    private var pipelineTask: Task<Void, Never>?

    // Publishing (single-video flow)
    private(set) var isPublishing = false
    private(set) var publishReport: PublishReport?
    private(set) var publishError: String?
    /// True while "Publish all approved" runs over the shorts.
    private(set) var isPublishingAll = false

    var isBusy: Bool {
        switch phase {
        case .processing, .transcribing, .findingMoments, .renderingHighlight: return true
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
            startShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
        }
    }

    // MARK: - Single-video flow (unchanged behaviour)

    private func processSingleVideo(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        guard let engine = modelManager.engine else {
            errorMessage = "The model is still getting ready — give it a moment, then drop the video again."
            return
        }

        job = newJob
        variants = []
        detectedLanguage = nil
        phase = .processing

        do {
            let result = try await GemmaService.generate(
                job: newJob,
                engine: engine,
                languageOverride: settings.languageOverride,
                styleExamples: settings.styleExamples)
            variants = result.variants
            detectedLanguage = result.detectedLanguage
            phase = .results
        } catch {
            errorMessage = "Couldn't generate posts for that video. \(error.localizedDescription)"
            job = nil
            phase = .empty
        }
    }

    // MARK: - Shorts flow

    private func startShortsPipeline(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) {
        cleanupClipTempFiles()
        cleanupHighlightTempFile()
        job = newJob
        clips = []
        highlightVideo = nil
        variants = []
        pipelineError = nil
        phase = .transcribing

        pipelineTask = Task {
            await self.runShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
        }
    }

    private func runShortsPipeline(job: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        let pipelineStart = Date()
        Self.log("pipeline start — copywriter=\(settings.copywriterModel.rawValue)")
        do {
            // 1. Transcript: sidecar .srt/.vtt if present, else WhisperKit.
            phase = .transcribing
            let t0 = Date()
            let transcript = try await transcription.transcript(
                for: job.url, languageHint: settings.languageOverride)
            // Trust the language of the actual text over Whisper's 30s auto-detect.
            let captionLanguage = transcript.contentLanguage ?? transcript.language
            let outputLanguage = settings.languageOverride.trimmed.isEmpty
                ? captionLanguage
                : settings.languageOverride
            Self.log("transcript ready in \(Self.elapsed(since: t0)) — whisper=\(transcript.language ?? "?"), text=\(captionLanguage ?? "?"), output=\(outputLanguage ?? "?")")
            try Task.checkCancellation()

            // 2. Plan the knowledge highlight with MiMo.
            phase = .findingMoments
            let t1 = Date()
            Self.log("director selected — MiMo API (\(settings.mimoModelID.trimmed.isEmpty ? "mimo-v2.5-pro" : settings.mimoModelID.trimmed))")
            let mimo = MimoService(
                apiKey: settings.mimoAPIKey,
                modelID: settings.mimoModelID,
                baseURL: settings.mimoBaseURL)
            let plan = try await mimo.planHighlight(
                transcript: transcript.srtLike(),
                language: outputLanguage,
                sourceDuration: job.durationSeconds)
            Self.log("highlight plan ready in \(Self.elapsed(since: t1)) — \(plan.segments.count) segment(s), \(Int(plan.duration.rounded()))s")
            try Task.checkCancellation()

            // 3. Render one highlight video from the selected ranges.
            phase = .renderingHighlight
            let t2 = Date()
            let renderTranscript = try await transcriptForHighlightSubtitles(
                transcript,
                plan: plan,
                settings: settings,
                mimo: mimo)
            Self.log("render highlight — aspect=\(settings.highlightAspectMode.rawValue), subtitles=\(settings.highlightSubtitleLanguage.rawValue)")
            let outputURL = try await MediaExtractor.renderHighlight(
                from: job.url,
                plan: plan,
                transcript: renderTranscript,
                aspectMode: settings.highlightAspectMode)
            highlightVideo = HighlightVideo(
                plan: plan,
                url: outputURL,
                aspectMode: settings.highlightAspectMode,
                durationSeconds: plan.duration)
            phase = .highlightResults
            Self.log("highlight rendered in \(Self.elapsed(since: t2)); pipeline done in \(Self.elapsed(since: pipelineStart)) total")
        } catch is CancellationError {
            cleanupClipTempFiles()
            cleanupHighlightTempFile()
            clips = []
            highlightVideo = nil
            self.job = nil
            phase = .empty
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't make a highlight from that video. \(error.localizedDescription)"
            self.job = nil
            clips = []
            highlightVideo = nil
            phase = .empty
        }
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

        let selectedIndices = transcript.segments.indices.filter { index in
            let cue = transcript.segments[index]
            return plan.segments.contains { segment in
                cue.end > segment.start && cue.start < segment.end
            }
        }
        guard !selectedIndices.isEmpty else { return transcript }

        Self.log("translate highlight subtitles — target=\(targetLanguage), cues=\(selectedIndices.count)")
        let selectedSegments = selectedIndices.map { transcript.segments[$0] }
        let translated = try await mimo.translateSubtitleSegments(
            selectedSegments,
            targetLanguage: targetLanguage)
        var output = transcript.segments
        for (offset, index) in selectedIndices.enumerated() where offset < translated.count {
            output[index] = translated[offset]
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
        job = nil
        variants = []
        clips = []
        highlightVideo = nil
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
