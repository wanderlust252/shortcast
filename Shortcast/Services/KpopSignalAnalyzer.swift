import AVFoundation
import CoreGraphics
import Foundation
import Vision

struct KpopSignalCandidate: Sendable, Equatable {
    var start: Double
    var end: Double
    var score: Double
    var reasons: [String]
    var transcriptSnippet: String

    var duration: Double { end - start }

    var rangeLabel: String {
        HighlightSegment.label(start) + "-" + HighlightSegment.label(end)
    }
}

struct KpopAnalysisReport: Sendable, Equatable {
    var duration: Double
    var candidates: [KpopSignalCandidate]

    var promptContext: String {
        guard !candidates.isEmpty else {
            return "No strong local performance candidates were detected. Use the transcript cautiously and avoid guessing visual details."
        }

        return candidates.enumerated().map { index, candidate in
            let reasons = candidate.reasons.joined(separator: "; ")
            let snippet = candidate.transcriptSnippet.isEmpty
                ? "No nearby transcript/lyrics."
                : candidate.transcriptSnippet
            return """
            \(index + 1). \(candidate.rangeLabel) score=\(Self.scoreLabel(candidate.score))
               signals: \(reasons)
               nearby text: \(snippet)
            """
        }
        .joined(separator: "\n")
    }

    private static func scoreLabel(_ score: Double) -> String {
        String(format: "%.2f", min(max(score, 0), 1))
    }
}

enum KpopSignalAnalyzer {
    struct AudioSample: Sendable, Equatable {
        var time: Double
        var energy: Double
        var onset: Double
    }

    struct VisualSample: Sendable, Equatable {
        var time: Double
        var sceneChange: Double
        var faceCount: Int
        var brightness: Double
    }

    private struct ScoredWindow {
        var start: Double
        var end: Double
        var score: Double
        var audioEnergy: Double
        var audioOnset: Double
        var sceneChange: Double
        var faceDensity: Double
    }

    static func analyze(
        videoURL: URL,
        transcript: Transcript,
        sourceDuration: Double
    ) async -> KpopAnalysisReport {
        let audio = await audioSamples(from: videoURL)
        let visual = await visualSamples(from: videoURL, duration: sourceDuration)
        let candidates = buildCandidates(
            audioSamples: audio,
            visualSamples: visual,
            transcript: transcript,
            duration: sourceDuration)
        return KpopAnalysisReport(duration: sourceDuration, candidates: candidates)
    }

    static func buildCandidates(
        audioSamples: [AudioSample],
        visualSamples: [VisualSample],
        transcript: Transcript,
        duration: Double
    ) -> [KpopSignalCandidate] {
        guard duration > 0 else { return [] }
        guard !audioSamples.isEmpty || !visualSamples.isEmpty else {
            return fallbackCandidates(transcript: transcript, duration: duration)
        }

        let windowLength = min(max(duration / 8, 12), 24)
        let step = max(4, windowLength / 3)
        var windows: [ScoredWindow] = []
        var start = 0.0
        while start < duration {
            let end = min(duration, start + windowLength)
            guard end - start >= 8 else { break }
            let audioSlice = audioSamples.filter { $0.time >= start && $0.time < end }
            let visualSlice = visualSamples.filter { $0.time >= start && $0.time < end }

            let energy = average(audioSlice.map(\.energy))
            let onset = average(audioSlice.map(\.onset))
            let scene = average(visualSlice.map(\.sceneChange))
            let faces = average(visualSlice.map { min(Double($0.faceCount), 5) / 5 })

            let signalScore = (energy * 0.42) + (onset * 0.22) + (scene * 0.24) + (faces * 0.12)
            windows.append(ScoredWindow(
                start: start,
                end: end,
                score: signalScore,
                audioEnergy: energy,
                audioOnset: onset,
                sceneChange: scene,
                faceDensity: faces))
            start += step
        }

        if windows.isEmpty {
            return fallbackCandidates(transcript: transcript, duration: duration)
        }

        let ranked = windows
            .sorted { $0.score > $1.score }
            .reduce(into: [ScoredWindow]()) { selected, window in
                guard selected.count < 24 else { return }
                let overlapsTooMuch = selected.contains {
                    overlapRatio(window.start, window.end, $0.start, $0.end) > 0.45
                }
                if !overlapsTooMuch {
                    selected.append(window)
                }
            }
            .sorted { $0.start < $1.start }

        let maxScore = ranked.map(\.score).max() ?? 0
        guard maxScore > 0 else {
            return fallbackCandidates(transcript: transcript, duration: duration)
        }
        let normalized = ranked.map { window -> KpopSignalCandidate in
            let score = window.score / maxScore
            return KpopSignalCandidate(
                start: window.start,
                end: window.end,
                score: score,
                reasons: reasons(for: window),
                transcriptSnippet: transcript.slice(start: window.start, end: window.end).trimmed)
        }

        return normalized.isEmpty
            ? fallbackCandidates(transcript: transcript, duration: duration)
            : normalized
    }

    private static func audioSamples(from videoURL: URL) async -> [AudioSample] {
        do {
            guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
                return []
            }
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let file = try AVAudioFile(forReading: audioURL)
            let format = file.processingFormat
            let sampleRate = max(format.sampleRate, 1)
            let chunkFrames = AVAudioFrameCount(sampleRate * 0.5)
            var raw: [(time: Double, energy: Double)] = []

            while file.framePosition < file.length {
                let startFrame = file.framePosition
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                    break
                }
                try file.read(into: buffer, frameCount: chunkFrames)
                guard buffer.frameLength > 0,
                      let channels = buffer.floatChannelData
                else { continue }

                var sumSquares = 0.0
                let channelCount = Int(format.channelCount)
                let frameCount = Int(buffer.frameLength)
                for channel in 0..<channelCount {
                    let samples = channels[channel]
                    for frame in 0..<frameCount {
                        let value = Double(samples[frame])
                        sumSquares += value * value
                    }
                }
                let denom = max(1, frameCount * max(channelCount, 1))
                let rms = sqrt(sumSquares / Double(denom))
                raw.append((time: Double(startFrame) / sampleRate, energy: rms))
            }

            return normalizeAudio(raw)
        } catch {
            ShortcastTrace.log("kpop", "audio analysis skipped: \(ShortcastTrace.describe(error))")
            return []
        }
    }

    private static func normalizeAudio(_ raw: [(time: Double, energy: Double)]) -> [AudioSample] {
        guard !raw.isEmpty else { return [] }
        let sorted = raw.map(\.energy).sorted()
        let floor = sorted[max(0, Int(Double(sorted.count) * 0.1) - 1)]
        let ceiling = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let range = max(ceiling - floor, 0.000_001)
        var previous = 0.0

        return raw.map { item in
            let energy = min(max((item.energy - floor) / range, 0), 1)
            let onset = min(max((energy - previous) * 2.5, 0), 1)
            previous = energy
            return AudioSample(time: item.time, energy: energy, onset: onset)
        }
    }

    private static func visualSamples(from videoURL: URL, duration: Double) async -> [VisualSample] {
        guard duration > 0 else { return [] }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        let step = max(1.0, duration / 240.0)
        var output: [VisualSample] = []
        var previousFingerprint: [Double]?
        var t = 0.0

        while t < duration {
            autoreleasepool {
                do {
                    let image = try generator.copyCGImage(
                        at: CMTime(seconds: t, preferredTimescale: 600),
                        actualTime: nil)
                    let fingerprint = grayscaleFingerprint(image)
                    let sceneChange = previousFingerprint.map {
                        fingerprintDifference($0, fingerprint)
                    } ?? 0
                    previousFingerprint = fingerprint
                    output.append(VisualSample(
                        time: t,
                        sceneChange: sceneChange,
                        faceCount: faceCount(in: image),
                        brightness: average(fingerprint)))
                } catch {
                    ShortcastTrace.log("kpop", "visual sample skipped at \(t): \(error.localizedDescription)")
                }
            }
            t += step
        }

        return normalizeVisual(output)
    }

    private static func normalizeVisual(_ samples: [VisualSample]) -> [VisualSample] {
        guard !samples.isEmpty else { return [] }
        let changes = samples.map(\.sceneChange).sorted()
        let ceiling = max(changes[min(changes.count - 1, Int(Double(changes.count) * 0.95))], 0.000_001)
        return samples.map {
            VisualSample(
                time: $0.time,
                sceneChange: min(max($0.sceneChange / ceiling, 0), 1),
                faceCount: $0.faceCount,
                brightness: $0.brightness)
        }
    }

    private static func grayscaleFingerprint(_ image: CGImage) -> [Double] {
        let width = 12
        let height = 12
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels.map { Double($0) / 255.0 }
    }

    private static func faceCount(in image: CGImage) -> Int {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?.count ?? 0
        } catch {
            return 0
        }
    }

    private static func fingerprintDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let total = zip(lhs, rhs).reduce(0.0) { $0 + abs($1.0 - $1.1) }
        return total / Double(lhs.count)
    }

    private static func reasons(for window: ScoredWindow) -> [String] {
        var reasons: [String] = []
        if window.audioEnergy >= 0.58 { reasons.append("high music energy") }
        if window.audioOnset >= 0.18 { reasons.append("strong beat/onset changes") }
        if window.sceneChange >= 0.30 { reasons.append("camera or scene changes") }
        if window.faceDensity >= 0.25 { reasons.append("performer faces visible") }
        if reasons.isEmpty { reasons.append("balanced performance signal") }
        return reasons
    }

    private static func fallbackCandidates(transcript: Transcript, duration: Double) -> [KpopSignalCandidate] {
        let windowLength = min(max(duration / 8, 12), 24)
        let step = max(windowLength, duration / 8)
        var candidates: [KpopSignalCandidate] = []
        var start = 0.0
        while start < duration, candidates.count < 12 {
            let end = min(duration, start + windowLength)
            if end - start >= 8 {
                candidates.append(KpopSignalCandidate(
                    start: start,
                    end: end,
                    score: 0.35,
                    reasons: ["fallback timeline window"],
                    transcriptSnippet: transcript.slice(start: start, end: end).trimmed))
            }
            start += step
        }
        return candidates
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func overlapRatio(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Double {
        let overlap = max(0, min(aEnd, bEnd) - max(aStart, bStart))
        let shortest = max(0.000_001, min(aEnd - aStart, bEnd - bStart))
        return overlap / shortest
    }
}
