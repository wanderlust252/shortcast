import AVFoundation
import AppKit
import Foundation
import QuartzCore
import Vision

enum ShortcastTrace {
    private static let subsystem = "shortcast"

    static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Shortcast", isDirectory: true)
            .appendingPathComponent("shortcast.log")
    }

    static func log(_ category: String, _ message: String) {
        let line = "\(Self.timestamp()) [\(subsystem)/\(category)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        let url = logURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            FileHandle.standardError.write(Data("[shortcast/trace] log write failed: \(error)\n".utf8))
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [
            "localized=\"\(ns.localizedDescription)\"",
            "domain=\(ns.domain)",
            "code=\(ns.code)",
        ]
        if !ns.userInfo.isEmpty {
            let userInfo = ns.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "; ")
            parts.append("userInfo={\(userInfo)}")
        }
        return parts.joined(separator: " ")
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

enum MediaExtractorError: LocalizedError {
    case noVideoTrack
    case audioExportFailed(String)
    case clipExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That file doesn't contain a video track."
        case .audioExportFailed(let detail):
            return "Couldn't extract the audio track: \(detail)"
        case .clipExportFailed(let detail):
            return "Couldn't cut the clip: \(detail)"
        }
    }
}

/// Validates dropped videos and pulls the audio track into a temp file.
///
/// Frame sampling for the model is handled inside `Gemma4Engine` (it has its
/// own `Gemma4VideoProcessor`). The one thing the model can't do itself is read
/// audio out of a video container, so that is this type's job.
enum MediaExtractor {

    /// Builds a `VideoJob` from a dropped file URL, verifying it really is a video.
    static func makeJob(from url: URL) async throws -> VideoJob {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaExtractorError.noVideoTrack }
        let duration = try await asset.load(.duration)
        return VideoJob(url: url, durationSeconds: CMTimeGetSeconds(duration))
    }

    /// Extracts the audio track to a temporary `.m4a`. `maxSeconds` caps the
    /// export (default 35s, a little past Gemma's 30s audio window); pass `nil`
    /// to export the full track (used for transcribing a long video). Returns
    /// `nil` if the video has no audio track.
    static func extractAudio(from url: URL, maxSeconds: Double? = 35) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw MediaExtractorError.audioExportFailed("export session unavailable")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-audio-\(UUID().uuidString).m4a")

        if let maxSeconds {
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let cap = CMTime(seconds: min(duration, maxSeconds), preferredTimescale: 600)
            export.timeRange = CMTimeRange(start: .zero, duration: cap)
        }

        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            throw MediaExtractorError.audioExportFailed(error.localizedDescription)
        }
        return outputURL
    }

    /// Cuts `[start, start+duration]` out of a video into a temporary `.mp4`.
    /// Tries a passthrough export first (no re-encode → near-instant, original
    /// quality); falls back to a re-encode if the source codec/container can't
    /// passthrough. Keeps the original aspect ratio (9:16 reframing is a future
    /// enhancement). `.mp4` matches the content type Upload-Post expects.
    static func cutClip(from url: URL, start: Double, duration: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaExtractorError.noVideoTrack }

        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-clip-\(UUID().uuidString).mp4")

        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue
            }
            export.timeRange = range
            do {
                try await export.export(to: outputURL, as: .mp4)
                return outputURL
            } catch {
                // Passthrough can reject some codecs/ranges; try the re-encode.
                try? FileManager.default.removeItem(at: outputURL)
                if preset == AVAssetExportPresetHighestQuality {
                    throw MediaExtractorError.clipExportFailed(error.localizedDescription)
                }
            }
        }
        throw MediaExtractorError.clipExportFailed("no usable export preset")
    }

    /// Builds one highlight video from the selected ranges, optionally burns in
    /// the intro table of contents, lower-third subtitles, and restrained
    /// cross-dissolves between segments.
    static func renderHighlight(
        from url: URL,
        plan: HighlightPlan,
        transcript: Transcript,
        aspectMode: HighlightAspectMode,
        showIntroCard: Bool,
        exportQuality: ExportQualityMode
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let sourceDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let transform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        ShortcastTrace.log(
            "render",
            "highlight start source=\(url.path) duration=\(sourceDuration) natural=\(naturalSize) aspect=\(aspectMode.rawValue) planSegments=\(plan.segments.count) transcriptSegments=\(transcript.segments.count) hasAudio=\(audioTrack != nil)")

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaExtractorError.clipExportFailed("no video track") }

        var usableSegments: [RenderSegment] = []
        for segment in plan.segments {
            let startSeconds = min(max(segment.start, 0), sourceDuration)
            let endSeconds = min(max(segment.end, startSeconds), sourceDuration)
            guard endSeconds - startSeconds >= 0.5 else { continue }
            usableSegments.append(RenderSegment(segment: segment, sourceStart: startSeconds, sourceEnd: endSeconds))
        }
        guard !usableSegments.isEmpty else {
            throw MediaExtractorError.clipExportFailed("no usable highlight segments")
        }

        let transitions = makeTransitions(for: usableSegments)
        var placements: [ClipPlacement] = []
        let introDuration = showIntroCard ? HighlightPlan.introDuration : 0
        var destination = CMTime(seconds: introDuration, preferredTimescale: 600)
        for index in usableSegments.indices {
            let item = usableSegments[index]
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: item.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: item.duration, preferredTimescale: 600))
            try compVideo.insertTimeRange(sourceRange, of: videoTrack, at: destination)

            let audioTrackOut = audioTrack.flatMap { _ in
                composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            if let audioTrack, let audioTrackOut {
                try? audioTrackOut.insertTimeRange(sourceRange, of: audioTrack, at: destination)
            }

            placements.append(ClipPlacement(
                segment: item.segment,
                sourceStart: item.sourceStart,
                sourceEnd: item.sourceEnd,
                timelineStart: destination.seconds,
                duration: item.duration,
                videoTrack: compVideo,
                audioTrack: audioTrackOut))

            let overlap = index < transitions.count ? transitions[index] : 0
            ShortcastTrace.log(
                "render",
                "segment[\(index)] source=\(item.sourceStart)-\(item.sourceEnd) timeline=\(CMTimeGetSeconds(destination))-\(CMTimeGetSeconds(destination + sourceRange.duration)) transitionOut=\(overlap)")
            destination = destination + sourceRange.duration
        }

        let renderSize = renderSize(
            naturalSize: naturalSize,
            transform: transform,
            aspectMode: aspectMode)
        ShortcastTrace.log("render", "renderSize selected \(renderSize)")
        let finalTransform = videoTransform(
            naturalSize: naturalSize,
            transform: transform,
            renderSize: renderSize,
            aspectMode: aspectMode)
        let videoComposition = makeHighlightComposition(
            placements: placements,
            transitions: transitions,
            renderSize: renderSize,
            transform: finalTransform,
            plan: plan,
            transcript: transcript,
            showIntroCard: showIntroCard)

        guard let export = makeExportSession(asset: composition, quality: exportQuality)
        else { throw MediaExtractorError.clipExportFailed("export session unavailable") }
        export.videoComposition = videoComposition
        export.audioMix = makeAudioMix(placements: placements, transitions: transitions)
        let exportPlan = configureExport(
            export,
            quality: exportQuality,
            sourceURL: url,
            duration: CMTimeGetSeconds(composition.duration),
            renderSize: renderSize)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-highlight-\(UUID().uuidString).mp4")
        ShortcastTrace.log(
            "render",
            "export start output=\(outputURL.path) compositionDuration=\(CMTimeGetSeconds(composition.duration)) instructions=\(videoComposition.instructions.count) renderSize=\(videoComposition.renderSize) quality=\(exportQuality.rawValue) preset=\(export.presetName) \(exportPlan.logSummary)")
        do {
            try await export.export(to: outputURL, as: .mp4)
            ShortcastTrace.log("render", "export succeeded output=\(outputURL.path)")
            return outputURL
        } catch {
            let exportError = export.error.map(ShortcastTrace.describe) ?? "nil"
            ShortcastTrace.log(
                "render",
                "export failed thrown=\(ShortcastTrace.describe(error)) status=\(export.status.rawValue) exportError=\(exportError)")
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaExtractorError.clipExportFailed(ShortcastTrace.describe(error))
        }
    }

    /// Renders the entire source video with burned-in subtitles. Unlike
    /// `renderHighlight`, this keeps the source timeline intact: no intro card,
    /// cuts, joins, or transitions.
    static func renderSubtitledFullVideo(
        from url: URL,
        transcript: Transcript,
        aspectMode: HighlightAspectMode,
        exportQuality: ExportQualityMode
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let sourceDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let transform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        ShortcastTrace.log(
            "render",
            "full translation start source=\(url.path) duration=\(sourceDuration) natural=\(naturalSize) aspect=\(aspectMode.rawValue) transcriptSegments=\(transcript.segments.count) hasAudio=\(audioTrack != nil)")

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaExtractorError.clipExportFailed("no video track") }

        let sourceRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: sourceDuration, preferredTimescale: 600))
        try compVideo.insertTimeRange(sourceRange, of: videoTrack, at: .zero)

        if let audioTrack,
           let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        let renderSize = renderSize(
            naturalSize: naturalSize,
            transform: transform,
            aspectMode: aspectMode)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        configureFullVideoLayerInstruction(
            layerInstruction,
            sourceURL: url,
            naturalSize: naturalSize,
            transform: transform,
            renderSize: renderSize,
            aspectMode: aspectMode,
            totalDuration: sourceDuration)
        let videoComposition = makeFullVideoComposition(
            layerInstruction: layerInstruction,
            renderSize: renderSize,
            transcript: transcript,
            totalDuration: sourceDuration)

        guard let export = makeExportSession(asset: composition, quality: exportQuality)
        else { throw MediaExtractorError.clipExportFailed("export session unavailable") }
        export.videoComposition = videoComposition
        let exportPlan = configureExport(
            export,
            quality: exportQuality,
            sourceURL: url,
            duration: CMTimeGetSeconds(composition.duration),
            renderSize: renderSize)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-translated-\(UUID().uuidString).mp4")
        ShortcastTrace.log(
            "render",
            "full translation export start output=\(outputURL.path) compositionDuration=\(CMTimeGetSeconds(composition.duration)) instructions=\(videoComposition.instructions.count) renderSize=\(videoComposition.renderSize) quality=\(exportQuality.rawValue) preset=\(export.presetName) \(exportPlan.logSummary)")
        do {
            try await export.export(to: outputURL, as: .mp4)
            ShortcastTrace.log("render", "full translation export succeeded output=\(outputURL.path)")
            return outputURL
        } catch {
            let exportError = export.error.map(ShortcastTrace.describe) ?? "nil"
            ShortcastTrace.log(
                "render",
                "full translation export failed thrown=\(ShortcastTrace.describe(error)) status=\(export.status.rawValue) exportError=\(exportError)")
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaExtractorError.clipExportFailed(ShortcastTrace.describe(error))
        }
    }

    private struct RenderSegment {
        let segment: HighlightSegment
        let sourceStart: Double
        let sourceEnd: Double

        var duration: Double { sourceEnd - sourceStart }
    }

    private struct ClipPlacement {
        let segment: HighlightSegment
        let sourceStart: Double
        let sourceEnd: Double
        let timelineStart: Double
        let duration: Double
        let videoTrack: AVCompositionTrack
        let audioTrack: AVCompositionTrack?

        var timelineEnd: Double { timelineStart + duration }
    }

    private struct ExportPlan {
        let targetBitrateMbps: Double?
        let estimatedBytes: Int64?
        let sourceBitrateMbps: Double?

        var logSummary: String {
            let source = sourceBitrateMbps.map { String(format: "sourceBitrate=%.2fMbps", $0) }
                ?? "sourceBitrate=?"
            let target = targetBitrateMbps.map { String(format: "targetBitrate=%.2fMbps", $0) }
                ?? "targetBitrate=unlimited"
            let size = estimatedBytes.map { "estimatedLimit=\(Self.formatBytes($0))" }
                ?? "estimatedLimit=none"
            return "\(source) \(target) \(size)"
        }

        private static func formatBytes(_ bytes: Int64) -> String {
            let mib = Double(bytes) / 1_048_576
            if mib >= 1024 {
                return String(format: "%.2fGiB", mib / 1024)
            }
            return String(format: "%.0fMiB", mib)
        }
    }

    private static func makeExportSession(
        asset: AVAsset,
        quality: ExportQualityMode
    ) -> AVAssetExportSession? {
        // Keep the high-quality preset so AVFoundation preserves our explicit
        // videoComposition render size; fileLengthLimit below guides bitrate.
        let preferredPreset = AVAssetExportPresetHighestQuality
        _ = quality
        if let export = AVAssetExportSession(asset: asset, presetName: preferredPreset) {
            return export
        }
        return AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
    }

    @discardableResult
    private static func configureExport(
        _ export: AVAssetExportSession,
        quality: ExportQualityMode,
        sourceURL: URL,
        duration: Double,
        renderSize: CGSize
    ) -> ExportPlan {
        let sourceBitrate = sourceBitrateMbps(sourceURL: sourceURL, duration: duration)
        let targetBitrate = targetBitrateMbps(
            quality: quality,
            sourceBitrateMbps: sourceBitrate,
            renderSize: renderSize)
        let estimatedBytes = targetBitrate.map { bitrate in
            Int64((bitrate * 1_000_000 / 8 * max(duration, 1)).rounded())
        }
        if let estimatedBytes {
            export.fileLengthLimit = estimatedBytes
        }
        return ExportPlan(
            targetBitrateMbps: targetBitrate,
            estimatedBytes: estimatedBytes,
            sourceBitrateMbps: sourceBitrate)
    }

    private static func sourceBitrateMbps(sourceURL: URL, duration: Double) -> Double? {
        guard duration > 0,
              let fileSize = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0 else {
            return nil
        }
        return Double(fileSize) * 8 / duration / 1_000_000
    }

    private static func targetBitrateMbps(
        quality: ExportQualityMode,
        sourceBitrateMbps: Double?,
        renderSize: CGSize
    ) -> Double? {
        guard quality != .highestQuality else { return nil }

        let pixels = renderSize.width * renderSize.height
        let resolutionBand: (compact: Double, autoFloor: Double, autoCeiling: Double, balanced: Double)
        if pixels >= 2_000_000 {
            resolutionBand = (compact: 3.0, autoFloor: 3.5, autoCeiling: 6.0, balanced: 6.0)
        } else if pixels >= 900_000 {
            resolutionBand = (compact: 2.0, autoFloor: 2.5, autoCeiling: 4.5, balanced: 4.5)
        } else {
            resolutionBand = (compact: 1.2, autoFloor: 1.8, autoCeiling: 3.0, balanced: 3.0)
        }

        switch quality {
        case .smallerFile:
            return resolutionBand.compact
        case .balanced:
            return resolutionBand.balanced
        case .automatic:
            let sourceAware = sourceBitrateMbps.map { max($0 * 2.5, resolutionBand.autoFloor) }
                ?? resolutionBand.autoFloor
            return min(sourceAware, resolutionBand.autoCeiling)
        case .highestQuality:
            return nil
        }
    }

    private static func makeTransitions(for segments: [RenderSegment]) -> [Double] {
        guard segments.count > 1 else { return [] }
        return (0..<(segments.count - 1)).map { index in
            min(HighlightPlan.transitionDuration, segments[index].duration / 2, segments[index + 1].duration / 2)
        }
    }

    private static func renderSize(
        naturalSize: CGSize,
        transform: CGAffineTransform,
        aspectMode: HighlightAspectMode
    ) -> CGSize {
        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        switch aspectMode {
        case .vertical:
            return CGSize(width: 1080, height: 1920)
        case .original:
            let maxLongEdge: CGFloat = 1920
            let longEdge = max(orientedSize.width, orientedSize.height)
            guard longEdge > maxLongEdge else { return orientedSize }
            let scale = maxLongEdge / longEdge
            return CGSize(
                width: round(orientedSize.width * scale),
                height: round(orientedSize.height * scale))
        }
    }

    private static func videoTransform(
        naturalSize: CGSize,
        transform: CGAffineTransform,
        renderSize: CGSize,
        aspectMode: HighlightAspectMode
    ) -> CGAffineTransform {
        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let scale: CGFloat
        switch aspectMode {
        case .vertical:
            scale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        case .original:
            scale = min(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        }
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let translate = CGAffineTransform(
            translationX: (renderSize.width - scaledSize.width) / 2,
            y: (renderSize.height - scaledSize.height) / 2)
        return transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(translate)
    }

    private struct FaceSample {
        let time: Double
        let midX: CGFloat?
    }

    private struct FullVideoPanKeyframe {
        let time: Double
        let cropX: CGFloat
    }

    private static func configureFullVideoLayerInstruction(
        _ layer: AVMutableVideoCompositionLayerInstruction,
        sourceURL: URL,
        naturalSize: CGSize,
        transform: CGAffineTransform,
        renderSize: CGSize,
        aspectMode: HighlightAspectMode,
        totalDuration: Double
    ) {
        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard aspectMode == .vertical, orientedSize.width > orientedSize.height else {
            layer.setTransform(
                videoTransform(
                    naturalSize: naturalSize,
                    transform: transform,
                    renderSize: renderSize,
                    aspectMode: aspectMode),
                at: .zero)
            return
        }

        let samples = sampleFacesForFullVideo(sourceURL: sourceURL, duration: totalDuration)
        let withFace = samples.filter { $0.midX != nil }.count
        let trackable = !samples.isEmpty && Double(withFace) / Double(samples.count) >= 0.4
        guard trackable else {
            ShortcastTrace.log(
                "render",
                "full translation face tracking unavailable faceSamples=\(withFace)/\(samples.count); using center crop")
            layer.setTransform(
                videoTransform(
                    naturalSize: naturalSize,
                    transform: transform,
                    renderSize: renderSize,
                    aspectMode: aspectMode),
                at: .zero)
            return
        }

        let keyframes = fullVideoPanPath(from: samples, orientedSize: orientedSize, renderSize: renderSize)
        let frames = keyframes.isEmpty
            ? [FullVideoPanKeyframe(time: 0, cropX: 0)]
            : keyframes
        ShortcastTrace.log(
            "render",
            "full translation face tracking enabled faceSamples=\(withFace)/\(samples.count) keyframes=\(frames.count)")
        layer.setTransform(
            fullVideoTrackingTransform(
                cropX: frames[0].cropX,
                base: transform,
                orientedSize: orientedSize,
                renderSize: renderSize),
            at: .zero)
        for index in 0..<(frames.count - 1) {
            let startT = CMTime(seconds: frames[index].time, preferredTimescale: 600)
            let endT = CMTime(seconds: frames[index + 1].time, preferredTimescale: 600)
            guard endT > startT else { continue }
            layer.setTransformRamp(
                fromStart: fullVideoTrackingTransform(
                    cropX: frames[index].cropX,
                    base: transform,
                    orientedSize: orientedSize,
                    renderSize: renderSize),
                toEnd: fullVideoTrackingTransform(
                    cropX: frames[index + 1].cropX,
                    base: transform,
                    orientedSize: orientedSize,
                    renderSize: renderSize),
                timeRange: CMTimeRange(start: startT, end: endT))
        }
    }

    private static func sampleFacesForFullVideo(sourceURL: URL, duration: Double) -> [FaceSample] {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 512, height: 512)

        var samples: [FaceSample] = []
        var t = 0.0
        let step = 0.5
        while t < max(step, duration) {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                samples.append(FaceSample(time: t, midX: largestFaceMidX(in: cgImage)))
            } else {
                samples.append(FaceSample(time: t, midX: nil))
            }
            t += step
        }
        return samples
    }

    private static func largestFaceMidX(in cgImage: CGImage) -> CGFloat? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        let biggest = faces.max { a, b in
            (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
        }
        return biggest?.boundingBox.midX
    }

    private static func fullVideoPanPath(
        from samples: [FaceSample],
        orientedSize: CGSize,
        renderSize: CGSize
    ) -> [FullVideoPanKeyframe] {
        let scale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        let scaledW = orientedSize.width * scale
        let cropMaxX = max(0, scaledW - renderSize.width)
        let center = cropMaxX / 2

        var lastTarget = center
        let targets: [(time: Double, x: CGFloat)] = samples.map { sample in
            if let midX = sample.midX {
                lastTarget = min(max(midX * scaledW - renderSize.width / 2, 0), cropMaxX)
            }
            return (sample.time, lastTarget)
        }
        guard !targets.isEmpty else { return [FullVideoPanKeyframe(time: 0, cropX: center)] }

        let safeZone = renderSize.width * 0.18
        let maxSpeed = renderSize.width * 0.75
        var current = targets[0].x
        var keyframes = [FullVideoPanKeyframe(time: targets[0].time, cropX: current)]

        for index in 1..<targets.count {
            let dt = targets[index].time - targets[index - 1].time
            let target = targets[index].x
            let diff = target - current
            if abs(diff) > safeZone {
                let step = min(abs(diff), maxSpeed * dt)
                current += (diff > 0 ? 1 : -1) * step
                current = min(max(current, 0), cropMaxX)
            }
            keyframes.append(FullVideoPanKeyframe(time: targets[index].time, cropX: current))
        }
        return keyframes
    }

    private static func fullVideoTrackingTransform(
        cropX: CGFloat,
        base: CGAffineTransform,
        orientedSize: CGSize,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let scale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        let scaledH = orientedSize.height * scale
        let y = (renderSize.height - scaledH) / 2
        return base
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -cropX, y: y))
    }

    private static func makeHighlightComposition(
        placements: [ClipPlacement],
        transitions: [Double],
        renderSize: CGSize,
        transform: CGAffineTransform,
        plan: HighlightPlan,
        transcript: Transcript,
        showIntroCard: Bool
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: totalDuration(for: placements), preferredTimescale: 600))
        instruction.backgroundColor = NSColor.black.cgColor
        if let track = placements.first?.videoTrack {
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layer]
        }
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)
        if showIntroCard {
            parentLayer.addSublayer(makeIntroLayer(plan: plan, renderSize: renderSize))
        }
        parentLayer.addSublayer(makeTransitionLayer(
            placements: placements,
            transitions: transitions,
            renderSize: renderSize))

        let totalDuration = placements.last?.timelineEnd ?? HighlightPlan.introDuration
        if let subtitleLayer = makeSubtitleOverlayLayer(
            placements: placements,
            transcript: transcript,
            renderSize: renderSize,
            totalDuration: totalDuration) {
            parentLayer.addSublayer(subtitleLayer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        return videoComposition
    }

    private static func makeFullVideoComposition(
        layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        transcript: Transcript,
        totalDuration: Double
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: totalDuration, preferredTimescale: 600))
        instruction.backgroundColor = NSColor.black.cgColor
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        if let subtitleLayer = makeFullSubtitleOverlayLayer(
            transcript: transcript,
            renderSize: renderSize,
            totalDuration: totalDuration) {
            parentLayer.addSublayer(subtitleLayer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        return videoComposition
    }

    private static func totalDuration(for placements: [ClipPlacement]) -> Double {
        placements.last?.timelineEnd ?? HighlightPlan.introDuration
    }

    private static func makeAudioMix(
        placements: [ClipPlacement],
        transitions: [Double]
    ) -> AVMutableAudioMix? {
        var params: [AVMutableAudioMixInputParameters] = []
        for index in placements.indices {
            guard let audioTrack = placements[index].audioTrack else { continue }
            let placement = placements[index]
            let input = AVMutableAudioMixInputParameters(track: audioTrack)
            input.setVolume(1, at: CMTime(seconds: placement.timelineStart, preferredTimescale: 600))

            if index > 0 {
                let duration = transitions[index - 1]
                let range = CMTimeRange(
                    start: CMTime(seconds: placement.timelineStart, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
                input.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range)
            }
            if index < transitions.count {
                let duration = transitions[index]
                let range = CMTimeRange(
                    start: CMTime(seconds: placement.timelineEnd - duration, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
                input.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
            }
            params.append(input)
        }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    private static func makeTransitionLayer(
        placements: [ClipPlacement],
        transitions: [Double],
        renderSize: CGSize
    ) -> CALayer {
        let total = max(totalDuration(for: placements), HighlightPlan.introDuration)
        var points: [(time: Double, opacity: Double)] = [(0, 0)]
        for index in transitions.indices where index < placements.count {
            let duration = transitions[index]
            guard duration > 0 else { continue }
            let cut = placements[index].timelineEnd
            let half = duration / 2
            let start = max(0, cut - half)
            let end = min(total, cut + half)
            points.append((start, 0))
            points.append((cut, 0.35))
            points.append((end, 0))
        }
        points.append((total, 0))

        var times: [Double] = []
        var values: [Double] = []
        for point in points.sorted(by: { $0.time < $1.time }) {
            let clamped = min(max(point.time, 0), total)
            if let last = times.last, clamped <= last {
                values[values.count - 1] = point.opacity
            } else {
                times.append(clamped)
                values.append(point.opacity)
            }
        }

        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.backgroundColor = NSColor.black.cgColor
        layer.opacity = 0

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / total) }
        animation.duration = total
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "transitionOpacity")
        return layer
    }

    private static func makeIntroLayer(plan: HighlightPlan, renderSize: CGSize) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.backgroundColor = NSColor.white.cgColor
        layer.contentsScale = bitmapScale(for: renderSize)
        layer.contentsGravity = .resize
        layer.contents = renderIntroImage(plan: plan, size: renderSize)
        addVisibilityAnimation(
            to: layer,
            start: 0,
            end: HighlightPlan.introDuration,
            total: HighlightPlan.renderedDuration(for: plan.segments))
        return layer
    }

    private static func renderIntroImage(plan: HighlightPlan, size: CGSize) -> CGImage? {
        let scale = bitmapScale(for: size)
        let pxW = max(1, Int(size.width * scale))
        let pxH = max(1, Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)

        let background = NSColor(calibratedWhite: 0.975, alpha: 1)
        background.setFill()
        CGRect(origin: .zero, size: size).fill()

        let isVertical = size.height > size.width * 1.2
        let marginX = size.width * (isVertical ? 0.085 : 0.105)
        let marginY = size.height * (isVertical ? 0.07 : 0.095)
        let contentWidth = size.width - marginX * 2
        let contentRect = CGRect(
            x: marginX,
            y: marginY,
            width: contentWidth,
            height: size.height - marginY * 2)

        let title = plan.title.trimmed.isEmpty ? "Highlight" : plan.title.trimmed
        let titleMaxHeight = contentRect.height * (isVertical ? 0.24 : 0.26)
        let titleFont = fittingFont(
            for: title,
            width: contentWidth,
            maxHeight: titleMaxHeight,
            maxSize: min(size.width * (isVertical ? 0.095 : 0.048), size.height * 0.13),
            minSize: max(30, min(size.width, size.height) * 0.032),
            weight: .heavy,
            alignment: .center,
            lineSpacing: 2)
        let titleStyle = paragraph(alignment: .center, lineBreak: .byWordWrapping, lineSpacing: 2)
        let titleText = NSAttributedString(
            string: title,
            attributes: [.font: titleFont, .foregroundColor: NSColor.black, .paragraphStyle: titleStyle])
        let titleHeight = min(
            titleMaxHeight,
            ceil(measuredHeight(titleText, width: contentWidth)))
        titleText.draw(
            with: CGRect(x: contentRect.minX, y: contentRect.minY, width: contentWidth, height: titleHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        var cursorY = contentRect.minY + titleHeight + size.height * (isVertical ? 0.026 : 0.025)
        if !plan.summary.trimmed.isEmpty {
            let summaryFont = NSFont.systemFont(
                ofSize: max(20, min(size.width, size.height) * (isVertical ? 0.029 : 0.026)),
                weight: .medium)
            let summaryStyle = paragraph(alignment: .center, lineBreak: .byWordWrapping, lineSpacing: 3)
            let summaryText = NSAttributedString(
                string: plan.summary.trimmed,
                attributes: [
                    .font: summaryFont,
                    .foregroundColor: NSColor.black.withAlphaComponent(0.68),
                    .paragraphStyle: summaryStyle,
                ])
            let summaryLineHeight = summaryFont.ascender - summaryFont.descender + summaryFont.leading
            let summaryMaxHeight = summaryLineHeight * (isVertical ? 4.2 : 2.4)
            let summaryHeight = min(summaryMaxHeight, ceil(measuredHeight(summaryText, width: contentWidth * 0.92)))
            summaryText.draw(
                with: CGRect(
                    x: contentRect.minX + contentWidth * 0.04,
                    y: cursorY,
                    width: contentWidth * 0.92,
                    height: summaryHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            cursorY += summaryHeight + size.height * (isVertical ? 0.04 : 0.055)
        } else {
            cursorY += size.height * (isVertical ? 0.03 : 0.05)
        }

        let remainingHeight = contentRect.maxY - cursorY
        let maxItems = isVertical ? 7 : 5
        let items = Array(plan.segments.prefix(maxItems))
        if !items.isEmpty, remainingHeight > 80 {
            let labelFont = NSFont.monospacedDigitSystemFont(
                ofSize: max(17, min(size.width, size.height) * (isVertical ? 0.022 : 0.018)),
                weight: .semibold)
            let rowGap = max(8, size.height * (isVertical ? 0.011 : 0.015))
            let rowHeight = (remainingHeight - rowGap * CGFloat(max(0, items.count - 1))) / CGFloat(items.count)
            let titleAvailableWidth = contentWidth - (isVertical ? 145 : 180)
            let itemFont = fittingFont(
                for: items.map { $0.title.trimmed.isEmpty ? $0.rangeLabel : $0.title.trimmed }.joined(separator: "\n"),
                width: titleAvailableWidth,
                maxHeight: max(34, rowHeight - 4) * CGFloat(items.count),
                maxSize: max(22, min(size.width, size.height) * (isVertical ? 0.038 : 0.031)),
                minSize: max(17, min(size.width, size.height) * 0.021),
                weight: .bold,
                alignment: .left,
                lineSpacing: 1)

            for (index, segment) in items.enumerated() {
                let rowY = cursorY + CGFloat(index) * (rowHeight + rowGap)
                let rowRect = CGRect(x: contentRect.minX, y: rowY, width: contentWidth, height: rowHeight)
                let number = String(format: "%02d", index + 1)
                let time = segment.rangeLabel
                let markerWidth: CGFloat = isVertical ? 112 : 142
                let markerText = NSAttributedString(
                    string: "\(number)  \(time)",
                    attributes: [
                        .font: labelFont,
                        .foregroundColor: NSColor.black.withAlphaComponent(0.52),
                        .paragraphStyle: paragraph(alignment: .left, lineBreak: .byClipping),
                    ])
                markerText.draw(
                    with: CGRect(x: rowRect.minX, y: rowRect.minY + 3, width: markerWidth, height: rowRect.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])

                let itemTitle = segment.title.trimmed.isEmpty ? segment.rangeLabel : segment.title.trimmed
                let itemText = NSAttributedString(
                    string: itemTitle,
                    attributes: [
                        .font: itemFont,
                        .foregroundColor: NSColor.black,
                        .paragraphStyle: paragraph(alignment: .left, lineBreak: .byTruncatingTail, lineSpacing: 1),
                    ])
                itemText.draw(
                    with: CGRect(
                        x: rowRect.minX + markerWidth + 18,
                        y: rowRect.minY,
                        width: rowRect.width - markerWidth - 18,
                        height: rowRect.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func paragraph(
        alignment: NSTextAlignment,
        lineBreak: NSLineBreakMode,
        lineSpacing: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        style.lineSpacing = lineSpacing
        return style
    }

    private static func measuredHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    }

    private static func fittingFont(
        for text: String,
        width: CGFloat,
        maxHeight: CGFloat,
        maxSize: CGFloat,
        minSize: CGFloat,
        weight: NSFont.Weight,
        alignment: NSTextAlignment,
        lineSpacing: CGFloat
    ) -> NSFont {
        var size = max(maxSize, minSize)
        while size > minSize {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: paragraph(
                        alignment: alignment,
                        lineBreak: .byWordWrapping,
                        lineSpacing: lineSpacing),
                ])
            if measuredHeight(attributed, width: width) <= maxHeight {
                return font
            }
            size -= 2
        }
        return NSFont.systemFont(ofSize: minSize, weight: weight)
    }

    private static func makeSubtitleOverlayLayer(
        placements: [ClipPlacement],
        transcript: Transcript,
        renderSize: CGSize,
        totalDuration: Double
    ) -> CALayer? {
        let fontSize = max(24, min(renderSize.width, renderSize.height) * 0.042)
        let paddingX = fontSize * 0.72
        let paddingY = fontSize * 0.42
        let overlayWidth = renderSize.width * 0.88
        let overlayHeight = fontSize * 3.9
        let overlaySize = CGSize(width: overlayWidth, height: overlayHeight)

        guard let blank = transparentImage(size: overlaySize) else { return nil }
        var frames: [(time: Double, image: CGImage)] = [(0, blank)]

        for placement in placements {
            for cue in transcript.segments where cue.end > placement.sourceStart && cue.start < placement.sourceEnd {
                let sourceStart = max(cue.start, placement.sourceStart)
                let sourceEnd = min(cue.end, placement.sourceEnd)
                guard sourceEnd - sourceStart >= 0.2 else { continue }
                let timelineStart = placement.timelineStart + (sourceStart - placement.sourceStart)
                let timelineEnd = placement.timelineStart + (sourceEnd - placement.sourceStart)
                let text = SubtitleFormatter.displayText(cue.text)
                guard !text.isEmpty else { continue }
                let subtitleImage = renderSubtitleImage(
                    text: text,
                    size: overlaySize,
                    fontSize: fontSize,
                    paddingX: paddingX,
                    paddingY: paddingY) ?? blank
                appendSubtitleFrame(&frames, time: timelineStart, image: subtitleImage)
                appendSubtitleFrame(&frames, time: timelineEnd, image: blank)
            }
        }

        guard frames.count > 1 else { return nil }
        appendSubtitleFrame(&frames, time: totalDuration, image: blank)
        ShortcastTrace.log("render", "subtitle overlay frames=\(frames.count)")

        let layer = CALayer()
        layer.frame = CGRect(
            x: (renderSize.width - overlayWidth) / 2,
            y: renderSize.height * 0.075,
            width: overlayWidth,
            height: overlayHeight)
        layer.contentsScale = bitmapScale(for: overlaySize)
        layer.contentsGravity = .resizeAspect
        layer.contents = blank

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.map(\.image)
        animation.keyTimes = frames.map { NSNumber(value: $0.time / max(totalDuration, 0.1)) }
        animation.duration = max(totalDuration, 0.1)
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "subtitleContents")
        return layer
    }

    private static func makeFullSubtitleOverlayLayer(
        transcript: Transcript,
        renderSize: CGSize,
        totalDuration: Double
    ) -> CALayer? {
        let fontSize = max(24, min(renderSize.width, renderSize.height) * 0.042)
        let paddingX = fontSize * 0.72
        let paddingY = fontSize * 0.42
        let overlayWidth = renderSize.width * 0.88
        let overlayHeight = fontSize * 3.9
        let overlaySize = CGSize(width: overlayWidth, height: overlayHeight)

        guard let blank = transparentImage(size: overlaySize) else { return nil }
        var frames: [(time: Double, image: CGImage)] = [(0, blank)]

        for cue in transcript.segments {
            let sourceStart = min(max(cue.start, 0), totalDuration)
            let sourceEnd = min(max(cue.end, sourceStart), totalDuration)
            guard sourceEnd - sourceStart >= 0.2 else { continue }
            let text = SubtitleFormatter.displayText(cue.text)
            guard !text.isEmpty else { continue }
            let subtitleImage = renderSubtitleImage(
                text: text,
                size: overlaySize,
                fontSize: fontSize,
                paddingX: paddingX,
                paddingY: paddingY) ?? blank
            appendSubtitleFrame(&frames, time: sourceStart, image: subtitleImage)
            appendSubtitleFrame(&frames, time: sourceEnd, image: blank)
        }

        guard frames.count > 1 else { return nil }
        appendSubtitleFrame(&frames, time: totalDuration, image: blank)
        ShortcastTrace.log("render", "full subtitle overlay frames=\(frames.count)")

        let layer = CALayer()
        layer.frame = CGRect(
            x: (renderSize.width - overlayWidth) / 2,
            y: renderSize.height * 0.075,
            width: overlayWidth,
            height: overlayHeight)
        layer.contentsScale = bitmapScale(for: overlaySize)
        layer.contentsGravity = .resizeAspect
        layer.contents = blank

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.map(\.image)
        animation.keyTimes = frames.map { NSNumber(value: $0.time / max(totalDuration, 0.1)) }
        animation.duration = max(totalDuration, 0.1)
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "subtitleContents")
        return layer
    }

    private static func appendSubtitleFrame(
        _ frames: inout [(time: Double, image: CGImage)],
        time: Double,
        image: CGImage
    ) {
        let safeTime = max(0, time)
        if let last = frames.last, abs(last.time - safeTime) < 0.001 {
            frames[frames.count - 1] = (safeTime, image)
        } else if let last = frames.last, safeTime < last.time {
            frames.append((last.time + 0.001, image))
        } else {
            frames.append((safeTime, image))
        }
    }

    private static func renderSubtitleImage(
        text: String,
        size: CGSize,
        fontSize: CGFloat,
        paddingX: CGFloat,
        paddingY: CGFloat
    ) -> CGImage? {
        let scale = bitmapScale(for: size)
        let pxW = max(1, Int(size.width * scale))
        let pxH = max(1, Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)

        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
                .shadow: shadow,
            ])
        let textRect = CGRect(
            x: paddingX,
            y: paddingY,
            width: size.width - paddingX * 2,
            height: size.height - paddingY * 2)
        let bounds = attributed.boundingRect(
            with: textRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let bandHeight = min(size.height, ceil(bounds.height) + paddingY * 2)
        let bandY = max(0, (size.height - bandHeight) / 2)
        let bandRect = CGRect(x: 0, y: bandY, width: size.width, height: bandHeight)
        NSColor.black.withAlphaComponent(0.48).setFill()
        NSBezierPath(roundedRect: bandRect, xRadius: min(14, bandHeight * 0.22), yRadius: min(14, bandHeight * 0.22)).fill()

        let drawRect = CGRect(
            x: paddingX,
            y: bandY + max(paddingY * 0.55, (bandHeight - ceil(bounds.height)) / 2),
            width: size.width - paddingX * 2,
            height: ceil(bounds.height))
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func transparentImage(size: CGSize) -> CGImage? {
        let pxW = max(1, Int(size.width))
        let pxH = max(1, Int(size.height))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        return ctx.makeImage()
    }

    private static func bitmapScale(for size: CGSize) -> CGFloat {
        let maxDimension: CGFloat = 4096
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 1 }
        return max(1, min(2, maxDimension / longest))
    }

    private static func addVisibilityAnimation(to layer: CALayer, start: Double, end: Double, total: Double) {
        let safeTotal = max(total, end, 0.1)
        let safeStart = min(max(start, 0), safeTotal)
        let safeEnd = min(max(end, safeStart), safeTotal)
        let fade = min(0.035, safeTotal / 100)

        var points: [(time: Double, value: Double)] = []
        if safeStart <= 0 {
            points.append((0, 1))
        } else {
            points.append((0, 0))
            points.append((max(0, safeStart - fade), 0))
            points.append((safeStart, 1))
        }

        if safeEnd > safeStart {
            points.append((safeEnd, 1))
        }
        if safeEnd < safeTotal {
            points.append((min(safeTotal, safeEnd + fade), 0))
            points.append((safeTotal, 0))
        } else if points.last?.time != safeTotal {
            points.append((safeTotal, 1))
        }

        var times: [Double] = []
        var values: [Double] = []
        for point in points {
            let clampedTime = min(max(point.time, 0), safeTotal)
            if let last = times.last, clampedTime <= last {
                values[values.count - 1] = point.value
            } else {
                times.append(clampedTime)
                values.append(point.value)
            }
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = values
        anim.keyTimes = times.map { NSNumber(value: $0 / safeTotal) }
        anim.duration = safeTotal
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "visibility")
        layer.opacity = 0
    }
}
