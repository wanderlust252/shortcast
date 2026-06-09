import AVFoundation
import Foundation

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

    /// Builds one highlight video by concatenating selected ranges from the
    /// source. Keeps source aspect ratio for `.original`; renders a centered
    /// 1080x1920 crop for `.vertical`.
    static func renderHighlight(
        from url: URL,
        segments: [HighlightSegment],
        aspectMode: HighlightAspectMode
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let sourceDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let transform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaExtractorError.clipExportFailed("no video track") }
        compVideo.preferredTransform = transform

        let compAudio = audioTrack.flatMap { _ in
            composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var destination = CMTime.zero
        var insertedRanges: [(start: CMTime, duration: CMTime)] = []
        for segment in segments {
            let startSeconds = min(max(segment.start, 0), sourceDuration)
            let endSeconds = min(max(segment.end, startSeconds), sourceDuration)
            guard endSeconds - startSeconds >= 0.5 else { continue }

            let range = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600))
            try compVideo.insertTimeRange(range, of: videoTrack, at: destination)
            if let audioTrack, let compAudio {
                try? compAudio.insertTimeRange(range, of: audioTrack, at: destination)
            }
            insertedRanges.append((destination, range.duration))
            destination = destination + range.duration
        }
        guard destination.seconds > 0 else {
            throw MediaExtractorError.clipExportFailed("no usable highlight segments")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-highlight-\(UUID().uuidString).mp4")

        let videoComposition: AVMutableVideoComposition?
        switch aspectMode {
        case .original:
            videoComposition = nil
        case .vertical:
            videoComposition = makeVerticalComposition(
                compositionTrack: compVideo,
                insertedRanges: insertedRanges,
                naturalSize: naturalSize,
                transform: transform)
        }

        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
                continue
            }
            export.videoComposition = videoComposition
            do {
                try await export.export(to: outputURL, as: .mp4)
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                if preset == AVAssetExportPresetPassthrough {
                    throw MediaExtractorError.clipExportFailed(error.localizedDescription)
                }
            }
        }
        throw MediaExtractorError.clipExportFailed("no usable export preset")
    }

    private static func makeVerticalComposition(
        compositionTrack: AVCompositionTrack,
        insertedRanges: [(start: CMTime, duration: CMTime)],
        naturalSize: CGSize,
        transform: CGAffineTransform
    ) -> AVMutableVideoComposition {
        let renderSize = CGSize(width: 1080, height: 1920)
        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let scale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let translate = CGAffineTransform(
            translationX: (renderSize.width - scaledSize.width) / 2,
            y: (renderSize.height - scaledSize.height) / 2)
        let finalTransform = transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(translate)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = insertedRanges.map { range in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: range.start, duration: range.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            layer.setTransform(finalTransform, at: range.start)
            instruction.layerInstructions = [layer]
            return instruction
        }
        return videoComposition
    }
}
