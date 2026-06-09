import AVFoundation
import Foundation

enum ProductDiscoveryService {

    struct ProductOption: Identifiable, Equatable, Sendable {
        var id: String { label }
        let label: String
        let displayName: String
        let detections: [DetectionHit]

        var count: Int { detections.count }
        var firstTime: Double { detections.first?.time ?? 0 }
        var averageConfidence: Float {
            guard !detections.isEmpty else { return 0 }
            let total = detections.reduce(Float(0)) { $0 + $1.confidence }
            return total / Float(detections.count)
        }

        var summary: String {
            "\(count) hit\(count == 1 ? "" : "s") · first at \(Self.timeLabel(firstTime))"
        }

        private static func timeLabel(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    struct DetectionHit: Equatable, Sendable {
        let time: Double
        let confidence: Float
    }

    static func discoverProducts(
        videoURL: URL,
        interval: Double = 30
    ) async throws -> [ProductOption] {
        guard ProductFocusDetector.isModelBundled else { return [] }

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 640, height: 640)

        var grouped: [String: [DetectionHit]] = [:]
        let times = sampleTimes(duration: durationSeconds, interval: interval)
        for t in times {
            try Task.checkCancellation()
            let time = CMTime(seconds: t, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time) else { continue }
            let detections = await ProductFocusDetector.shared.detectProducts(in: cgImage)
            for detection in detections {
                grouped[detection.label, default: []].append(
                    DetectionHit(time: t, confidence: detection.confidence))
            }
        }

        return grouped.map { label, hits in
            ProductOption(
                label: label,
                displayName: displayName(for: label),
                detections: hits.sorted { $0.time < $1.time })
        }
        .sorted { a, b in
            if a.count == b.count { return a.averageConfidence > b.averageConfidence }
            return a.count > b.count
        }
    }

    static func candidates(
        for option: ProductOption,
        videoDuration: Double,
        clipLength: Double = 30
    ) -> [ClipCandidate] {
        let half = clipLength / 2
        let rawRanges = option.detections.map { hit -> (start: Double, end: Double) in
            let start = max(0, hit.time - half)
            let end = min(videoDuration, hit.time + half)
            return (start, end)
        }

        var merged: [(start: Double, end: Double)] = []
        for range in rawRanges.sorted(by: { $0.start < $1.start }) {
            guard var last = merged.popLast() else {
                merged.append(range)
                continue
            }
            if range.start <= last.end + 10 {
                last.end = max(last.end, range.end)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(range)
            }
        }

        return merged
            .map { range in
                let start = range.start
                let end = min(videoDuration, max(range.end, start + 8))
                return ClipCandidate(
                    start: start,
                    end: end,
                    why: "Detected \(option.displayName) in this part of the video.",
                    hook: option.displayName,
                    overlay: option.displayName)
            }
            .filter { $0.duration >= 5 }
    }

    private static func sampleTimes(duration: Double, interval: Double) -> [Double] {
        let step = max(5, interval)
        var times: [Double] = []
        var t = min(3, duration / 2)
        while t < duration {
            times.append(t)
            t += step
        }
        if times.isEmpty { times.append(duration / 2) }
        return times
    }

    private static func displayName(for label: String) -> String {
        label
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
