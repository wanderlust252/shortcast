import AVFoundation
import AppKit
import Foundation
import QuartzCore

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

    /// Builds one highlight video from the selected ranges, then burns in a
    /// five-second table of contents, lower-third subtitles, and restrained
    /// cross-dissolves between segments.
    static func renderHighlight(
        from url: URL,
        plan: HighlightPlan,
        transcript: Transcript,
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
        var destination = CMTime(seconds: HighlightPlan.introDuration, preferredTimescale: 600)
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
            transcript: transcript)

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw MediaExtractorError.clipExportFailed("export session unavailable") }
        export.videoComposition = videoComposition
        export.audioMix = makeAudioMix(placements: placements, transitions: transitions)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-highlight-\(UUID().uuidString).mp4")
        ShortcastTrace.log(
            "render",
            "export start output=\(outputURL.path) compositionDuration=\(CMTimeGetSeconds(composition.duration)) instructions=\(videoComposition.instructions.count) renderSize=\(videoComposition.renderSize)")
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

    private static func makeHighlightComposition(
        placements: [ClipPlacement],
        transitions: [Double],
        renderSize: CGSize,
        transform: CGAffineTransform,
        plan: HighlightPlan,
        transcript: Transcript
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
        parentLayer.addSublayer(makeIntroLayer(plan: plan, renderSize: renderSize))
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
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()

        let maxWidth = size.width * 0.78
        let titleFont = NSFont.systemFont(ofSize: max(34, size.width * 0.058), weight: .heavy)
        let bodyFont = NSFont.systemFont(ofSize: max(19, size.width * 0.031), weight: .regular)
        let bulletFont = NSFont.systemFont(ofSize: max(21, size.width * 0.034), weight: .semibold)

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byWordWrapping
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.alignment = .center
        bodyStyle.lineBreakMode = .byTruncatingTail
        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.alignment = .left
        bulletStyle.lineBreakMode = .byTruncatingTail
        bulletStyle.lineSpacing = 5

        let title = plan.title.trimmed.isEmpty ? "Highlight" : plan.title.trimmed
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: title + "\n",
            attributes: [.font: titleFont, .foregroundColor: NSColor.black, .paragraphStyle: titleStyle]))
        if !plan.summary.trimmed.isEmpty {
            text.append(NSAttributedString(
                string: plan.summary.trimmed + "\n\n",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.black.withAlphaComponent(0.72), .paragraphStyle: bodyStyle]))
        } else {
            text.append(NSAttributedString(string: "\n"))
        }
        for (index, segment) in plan.segments.prefix(8).enumerated() {
            let itemTitle = segment.title.trimmed.isEmpty ? segment.rangeLabel : segment.title.trimmed
            text.append(NSAttributedString(
                string: "\(index + 1). \(itemTitle)\n",
                attributes: [.font: bulletFont, .foregroundColor: NSColor.black, .paragraphStyle: bulletStyle]))
        }

        let bounds = text.boundingRect(
            with: CGSize(width: maxWidth, height: size.height * 0.86),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let rect = CGRect(
            x: (size.width - maxWidth) / 2,
            y: max(0, (size.height - ceil(bounds.height)) / 2),
            width: maxWidth,
            height: min(size.height * 0.86, ceil(bounds.height) + 8))
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
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
                let text = subtitleDisplayText(cue.text)
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

    private static func subtitleDisplayText(_ raw: String) -> String {
        var text = TranscriptionService.cleanTranscriptText(raw)
        let timecode = #"\d{1,2}:\d{2}(?::\d{2})?(?:[,.]\d{1,3})?"#
        let patterns = [
            #"(?:\(|\[)?"# + timecode + #"\s*(?:-->|-|–|—|to)\s*"# + timecode + #"(?:\)|\])?"#,
            #"^\s*(?:[\[(]?"# + timecode + #"[\])]?\s*)+"#,
            #"(?:\s*[\[(]?"# + timecode + #"[\])]?\s*)+$"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmed
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
