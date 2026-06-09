import Foundation
import Gemma4Swift
import Observation

/// Owns the Gemma 4 model lifecycle: first-run download, load, and the loaded
/// engine. Drives the download UI through `phase`.
@MainActor
@Observable
final class ModelManager {

    /// The model Shortcast ships with for video/audio captioning.
    static let defaultMultimodalProfile = LocalModelProfile.gemmaE4B

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double, detail: String)
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var engine: Gemma4Engine?
    private(set) var activeMultimodalProfile = LocalModelProfile.gemmaE4B
    private var loadedMultimodalProfileID: String?

    /// The "Director" — Qwen 3.5 9B, finds viral moments from a transcript.
    /// Loaded lazily on the first long-video drop, not at app launch.
    let momentFinder = MomentFinderService()

    // MARK: - Environment facts

    var systemRAMGB: Int { Gemma4ModelCache.systemRAMGB }
    var recommendedRAMGB: Int { activeMultimodalProfile.recommendedRAMGB }
    var hasEnoughRAM: Bool { systemRAMGB >= recommendedRAMGB }
    var isModelDownloaded: Bool {
        Gemma4ModelCache.isDownloaded(modelId: activeMultimodalProfile.modelID)
    }
    var estimatedDownloadGB: Int { Int(activeMultimodalProfile.estimatedDownloadGB.rounded(.up)) }
    var multimodalDisplayName: String { activeMultimodalProfile.displayName }
    var multimodalQuantizationLabel: String { activeMultimodalProfile.quantizationLabel }

    /// True when there's room to keep both Gemma and Qwen resident at once.
    /// Below this we load them sequentially (free the Director before Gemma
    /// captioning) to avoid swapping/OOM.
    var canKeepBothResident: Bool { systemRAMGB >= 24 }

    var isReady: Bool { engine != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading: true
        default: false
        }
    }

    // MARK: - Lifecycle

    /// Downloads (if needed) and loads the model. Safe to call repeatedly — it
    /// no-ops once the engine is ready or while work is already in flight.
    func prepareIfNeeded(profile: LocalModelProfile = LocalModelProfile.gemmaE4B) async {
        guard !isBusy else { return }
        guard profile.role == .multimodalCopywriter else {
            phase = .failed("Only multimodal copywriter profiles can be loaded for video captioning.")
            return
        }
        activeMultimodalProfile = profile
        let modelID = profile.modelID
        if let engine, loadedMultimodalProfileID == profile.id, engine.modelID == modelID {
            phase = .ready
            return
        }
        if loadedMultimodalProfileID != profile.id {
            engine = nil
            loadedMultimodalProfileID = nil
        }
        phase = isModelDownloaded ? .loading : .downloading(fraction: 0, detail: "Starting…")

        do {
            let prepared = try await Gemma4Engine.prepare(modelID: modelID) { [weak self] stage in
                Task { @MainActor in
                    guard let self else { return }
                    switch stage {
                    case .downloading(let progress):
                        self.phase = .downloading(
                            fraction: progress.fraction,
                            detail: progress.formattedProgress)
                    case .loading:
                        self.phase = .loading
                    }
                }
            }
            engine = prepared
            loadedMultimodalProfileID = profile.id
            phase = .ready
        } catch {
            loadedMultimodalProfileID = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// Clears a failed state so the user can retry.
    func resetForRetry() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Director (moment finder)

    /// Loads the Director (the user's chosen text model — Gemma 4 12B by default,
    /// or Qwen 3.5 9B) if needed. Switches model first when the pick changed.
    /// Called from the shorts pipeline, not launch.
    func prepareDirector(profile: ChatModelProfile) async {
        momentFinder.setProfile(profile)
        await momentFinder.prepareIfNeeded()
    }

    /// Loads whichever Director model is currently selected.
    func prepareDirectorIfNeeded() async {
        await momentFinder.prepareIfNeeded()
    }

    /// Frees the Director to make room for the Gemma copywriter on tight RAM.
    func freeDirectorIfMemoryTight() {
        guard !canKeepBothResident else { return }
        momentFinder.unload()
    }
}
