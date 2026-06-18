import AVFoundation
import Foundation
import NaturalLanguage
import Observation
@preconcurrency import WhisperKit

/// One spoken segment with its time range, in seconds.
struct TranscriptSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let speakerID: String?

    init(start: Double, end: Double, text: String, speakerID: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        let speaker = speakerID?.trimmed
        self.speakerID = speaker?.isEmpty == false ? speaker : nil
    }
}

/// A full transcript with timestamps. Fed to the Director to pick moments, and
/// sliced per clip to ground each caption in what's actually said there.
struct Transcript: Sendable, Equatable {
    let segments: [TranscriptSegment]
    let language: String?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Language inferred from the transcript text itself (BCP-47, e.g. "es").
    /// More reliable than Whisper's 30s auto-detect or a small model's guess —
    /// both of which mislabel (Spanish → "en" / pt-BR). Used to lock the caption
    /// language to what's actually spoken.
    var contentLanguage: String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(fullText)
        return recognizer.dominantLanguage?.rawValue
    }

    /// One `[MM:SS] text` line per segment — gives the Director timestamps to
    /// reason over.
    func srtLike() -> String {
        segments.map { segment in
            let speaker = segment.speakerID.map { "\($0): " } ?? ""
            return "[\(Self.mmss(segment.start))] \(speaker)\(segment.text.trimmed)"
        }
            .joined(separator: "\n")
    }

    /// Concatenated text of segments overlapping `[start, end]`.
    func slice(start: Double, end: Double) -> String {
        segments
            .filter { $0.end > start && $0.start < end }
            .map { $0.text.trimmed }
            .joined(separator: " ")
    }

    /// Keeps only cues that overlap selected highlight/montage ranges, clipping
    /// cue boundaries to the selected source ranges while preserving source-time
    /// coordinates for review and rendering.
    func clipped(to highlightSegments: [HighlightSegment]) -> Transcript {
        guard !segments.isEmpty, !highlightSegments.isEmpty else {
            return Transcript(segments: [], language: language)
        }

        var output: [TranscriptSegment] = []
        for highlight in highlightSegments {
            for cue in segments where cue.end > highlight.start && cue.start < highlight.end {
                let start = max(cue.start, highlight.start)
                let end = min(cue.end, highlight.end)
                guard end - start >= 0.2 else { continue }
                let text = cue.text.trimmed
                guard !text.isEmpty else { continue }
                output.append(TranscriptSegment(
                    start: start,
                    end: end,
                    text: text,
                    speakerID: cue.speakerID))
            }
        }
        return Transcript(segments: output, language: language)
    }

    private static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Produces a `Transcript` for a long video. Prefers an existing `.srt`/`.vtt`
/// sidecar (instant, no download); falls back to on-device WhisperKit only when
/// none is found — so the Whisper model never downloads for users who already
/// have transcripts.
@MainActor
@Observable
final class TranscriptionService {

    enum Phase: Equatable {
        case idle
        case downloadingModel(fraction: Double)
        /// After download: WhisperKit compiles/optimises the model for this Mac.
        /// First run only, slow, and reports no progress — hence a distinct phase
        /// so the UI doesn't sit at a misleading "Downloading 100%".
        case preparingModel
        case transcribing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var whisper: WhisperKit?

    /// Whisper variants to prefer, best-first; falls back to the device default
    /// (`openai_whisper-base`, which is multilingual). MUST be multilingual —
    /// distil-* models are English-only and turn other languages into phonetic
    /// gibberish, so they are deliberately excluded.
    private static let preferredVariants = [
        // Full large-v3 transcribes Spanish (and other languages) reliably. The
        // turbo variant was faster on paper but mis-decoded non-English audio
        // here, so it's deliberately not preferred.
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-small",
    ]

    // MARK: - Public

    /// Returns a transcript for `videoURL`, using a sidecar `.srt`/`.vtt` if one
    /// sits next to it, otherwise transcribing on-device. `languageHint` (e.g.
    /// "es", "Spanish") forces Whisper's decode language; empty = auto-detect.
    func transcript(
        for videoURL: URL,
        audioOverrideURL: URL? = nil,
        languageHint: String = "",
        backend: AppSettings.TranscriptionBackend = .whisper,
        mimo: MimoService? = nil
    ) async throws -> Transcript {
        if let sidecar = Self.findSidecar(for: videoURL),
           let parsed = Self.parseSubtitles(at: sidecar) {
            phase = .ready
            return parsed
        }
        if backend == .mimoASR {
            guard let mimo else { throw MimoError.notConfigured }
            return try await transcribeWithMimo(
                videoURL,
                audioOverrideURL: audioOverrideURL,
                languageHint: languageHint,
                mimo: mimo)
        }
        return try await transcribeOnDevice(
            videoURL,
            audioOverrideURL: audioOverrideURL,
            languageHint: languageHint)
    }

    /// True when a usable transcript exists without needing Whisper.
    static func hasSidecar(for videoURL: URL) -> Bool {
        findSidecar(for: videoURL) != nil
    }

    // MARK: - WhisperKit path

    private func transcribeOnDevice(
        _ videoURL: URL,
        audioOverrideURL: URL? = nil,
        languageHint: String = ""
    ) async throws -> Transcript {
        let audioURL: URL
        let shouldRemoveAudio: Bool
        if let audioOverrideURL {
            audioURL = audioOverrideURL
            shouldRemoveAudio = false
            Self.log("using external audio: \(audioOverrideURL.lastPathComponent)")
        } else {
            // Full audio (no cap) → temp .m4a.
            guard let extractedURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
                throw TranscriptionError.noAudio
            }
            audioURL = extractedURL
            shouldRemoveAudio = true
        }
        defer {
            if shouldRemoveAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        if whisper == nil {
            phase = .downloadingModel(fraction: 0)
            let support = WhisperKit.recommendedModels()
            let variant = Self.preferredVariants.first { support.supported.contains($0) }
                ?? support.default
            Self.log("whisper variant: \(variant) (supported: \(support.supported.joined(separator: ", ")))")
            let folder = try await WhisperKit.download(variant: variant) { @Sendable [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.phase = fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel
                }
            }
            // Loading specialises the CoreML model for the chosen compute units.
            // WhisperKit defaults the audio encoder to the Neural Engine, whose
            // specialization of large-v3 is pathologically slow on an M1 Pro
            // (~5 min). Forcing GPU skips that ANE specialization and loads +
            // transcribes far faster, with no first-run stall.
            phase = .preparingModel
            Self.log("preparing/loading model \(variant) on GPU…")
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU)
            whisper = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path, computeOptions: compute, load: true))
            Self.log("model loaded")
        }

        guard let whisper else { throw TranscriptionError.modelUnavailable }

        phase = .transcribing
        // Force language detection (or the user's override) so Spanish audio
        // isn't silently decoded as English. `language` nil + detectLanguage true
        // makes WhisperKit pick the spoken language instead of defaulting to en.
        var options = DecodingOptions()
        options.task = .transcribe
        if let code = Self.languageCode(from: languageHint) {
            options.language = code
            options.detectLanguage = false
            Self.log("forcing decode language: \(code)")
        } else {
            options.detectLanguage = true
        }
        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptSegment? in
            let text = Self.cleanTranscriptText(segment.text)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(start: Double(segment.start), end: Double(segment.end), text: text)
        }
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        Self.log("transcribed \(segments.count) segments, language=\(results.first?.language ?? "?")")
        phase = .ready
        return Transcript(segments: segments, language: results.first?.language)
    }

    private func transcribeWithMimo(
        _ videoURL: URL,
        audioOverrideURL: URL? = nil,
        languageHint: String,
        mimo: MimoService
    ) async throws -> Transcript {
        phase = .transcribing
        let t0 = Date()
        let audioURL: URL
        let shouldRemoveAudio: Bool
        if let audioOverrideURL {
            audioURL = audioOverrideURL
            shouldRemoveAudio = false
            Self.log("using external audio for mimo-asr: \(audioOverrideURL.lastPathComponent)")
        } else {
            guard let extractedURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
                throw TranscriptionError.noAudio
            }
            audioURL = extractedURL
            shouldRemoveAudio = true
        }
        defer {
            if shouldRemoveAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let chunks = try Self.makeMimoWAVChunks(from: audioURL, chunkSeconds: 60)
        defer {
            for chunk in chunks {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        Self.log("mimo-asr chunks=\(chunks.count)")
        var segments: [TranscriptSegment] = []
        for (index, chunk) in chunks.enumerated() {
            let data = try Data(contentsOf: chunk.url)
            let dataURL = "data:audio/wav;base64,\(data.base64EncodedString())"
            let text = try await mimo.transcribeAudio(dataURL: dataURL, language: languageHint)
            let cleaned = Self.cleanTranscriptText(text)
            if !cleaned.isEmpty {
                segments.append(TranscriptSegment(start: chunk.start, end: chunk.end, text: cleaned))
            }
            Self.log("mimo-asr chunk \(index + 1)/\(chunks.count) \(Self.mmss(chunk.start))-\(Self.mmss(chunk.end)) bytes=\(data.count)")
        }

        guard !segments.isEmpty else { throw TranscriptionError.empty }
        Self.log("mimo-asr transcribed \(segments.count) chunk segment(s) in \(String(format: "%.1fs", Date().timeIntervalSince(t0)))")
        phase = .ready
        let languageCode = Self.languageCode(from: languageHint)
        let supportedLanguage = ["en", "zh"].contains(languageCode ?? "") ? languageCode : nil
        return Transcript(segments: segments, language: supportedLanguage)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/transcribe] \(message)\n".utf8))
    }

    private static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private struct MimoAudioChunk {
        let url: URL
        let start: Double
        let end: Double
    }

    private static func makeMimoWAVChunks(from audioURL: URL, chunkSeconds: Double) throws -> [MimoAudioChunk] {
        let inputFile = try AVAudioFile(forReading: audioURL)
        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw TranscriptionError.audioConversionFailed
        }

        let outputFramesPerChunk = AVAudioFramePosition(chunkSeconds * outputFormat.sampleRate)
        var chunks: [MimoAudioChunk] = []
        var outputCursor: AVAudioFramePosition = 0

        while inputFile.framePosition < inputFile.length {
            let chunkStart = Double(outputCursor) / outputFormat.sampleRate
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("shortcast-mimo-asr-\(UUID().uuidString).wav")
            let outputFile = try AVAudioFile(forWriting: chunkURL, settings: outputFormat.settings)
            var chunkFrames: AVAudioFramePosition = 0

            while chunkFrames < outputFramesPerChunk && inputFile.framePosition < inputFile.length {
                let remainingInput = inputFile.length - inputFile.framePosition
                let inputFrameCount = AVAudioFrameCount(min(4096, remainingInput))
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: inputFrameCount)
                else { throw TranscriptionError.audioConversionFailed }
                try inputFile.read(into: inputBuffer, frameCount: inputFrameCount)
                guard inputBuffer.frameLength > 0 else { break }

                let ratio = outputFormat.sampleRate / inputFormat.sampleRate
                let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outputCapacity)
                else { throw TranscriptionError.audioConversionFailed }

                var didProvideInput = false
                var convertError: NSError?
                converter.convert(to: outputBuffer, error: &convertError) { _, status in
                    if didProvideInput {
                        status.pointee = .noDataNow
                        return nil
                    }
                    didProvideInput = true
                    status.pointee = .haveData
                    return inputBuffer
                }
                if let convertError { throw convertError }

                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                    chunkFrames += AVAudioFramePosition(outputBuffer.frameLength)
                    outputCursor += AVAudioFramePosition(outputBuffer.frameLength)
                }
            }

            converter.reset()
            let chunkEnd = Double(outputCursor) / outputFormat.sampleRate
            if chunkEnd > chunkStart {
                chunks.append(MimoAudioChunk(url: chunkURL, start: chunkStart, end: chunkEnd))
            } else {
                try? FileManager.default.removeItem(at: chunkURL)
                break
            }
        }

        return chunks
    }

    /// Maps a user language hint to a Whisper 2-letter code, or nil to auto-detect.
    /// Accepts codes ("es") and common names ("Spanish", "español").
    static func languageCode(from hint: String) -> String? {
        let h = hint.trimmed.lowercased()
        guard !h.isEmpty else { return nil }
        let names: [String: String] = [
            "spanish": "es", "español": "es", "espanol": "es", "castellano": "es",
            "english": "en", "inglés": "en", "ingles": "en",
            "portuguese": "pt", "português": "pt", "portugues": "pt",
            "french": "fr", "français": "fr", "francais": "fr",
            "german": "de", "alemán": "de", "aleman": "de", "deutsch": "de",
            "italian": "it", "italiano": "it",
            "catalan": "ca", "català": "ca",
            "vietnamese": "vi", "vietnam": "vi", "tiếng việt": "vi", "tieng viet": "vi",
        ]
        if let mapped = names[h] { return mapped }
        if h.count == 2 { return h }     // already a code
        return nil
    }

    // MARK: - Sidecar discovery + parsing

    /// Looks for `<basename>.srt` / `<basename>.vtt` next to the video.
    private static func findSidecar(for videoURL: URL) -> URL? {
        let base = videoURL.deletingPathExtension()
        for ext in ["srt", "vtt"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Parses an `.srt` or `.vtt` file into a `Transcript`. Tolerant of both
    /// `,` and `.` millisecond separators and optional cue indices/headers.
    static func parseSubtitles(at url: URL) -> Transcript? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var segments: [TranscriptSegment] = []
        // Split into cues on blank lines; a cue is any block with a "-->" line.
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeLineIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timecode(parts[0]),
                  let end = timecode(parts[1])
            else { continue }
            let cueText = lines[(timeLineIndex + 1)...].joined(separator: " ")
            let speakerCue = speakerPrefixedText(cueText)
            let text = cleanTranscriptText(speakerCue.text)
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(
                start: start,
                end: end,
                text: text,
                speakerID: speakerCue.speakerID))
        }
        guard !segments.isEmpty else { return nil }
        return Transcript(segments: segments, language: nil)
    }

    /// Parses `HH:MM:SS,mmm` / `MM:SS.mmm` (cue settings after the time ignored).
    static func timecode(_ raw: String) -> Double? {
        let token = raw.trimmed
            .split(separator: " ").first.map(String.init) ?? raw.trimmed
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":").map { Double($0) ?? 0 }
        switch fields.count {
        case 3: return fields[0] * 3600 + fields[1] * 60 + fields[2]
        case 2: return fields[0] * 60 + fields[1]
        case 1: return fields[0]
        default: return nil
        }
    }

    nonisolated static func cleanTranscriptText(_ raw: String) -> String {
        var text = raw.trimmed
        let clockTime = #"\d{1,2}:\d{2}(?::\d{2})?(?:[,.]\d{1,3})?"#
        let decimalTime = #"\d+(?:[,.]\d{1,3})?"#
        let patterns = [
            #"<\|[^|>]+\|>"#,
            #"(?:\(|\[)?"# + clockTime + #"\s*(?:-->|-|–|—|to)\s*"# + clockTime + #"(?:\)|\])?"#,
            #"(?:\(|\[)?"# + decimalTime + #"\s*(?:-->|-|–|—|to)\s*"# + decimalTime + #"(?:\)|\])?"#,
            #"^\s*(?:[\[(]?"# + clockTime + #"[\])]?\s*)+"#,
            #"(?:\s*[\[(]?"# + clockTime + #"[\])]?\s*)+$"#,
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

    private static func speakerPrefixedText(_ raw: String) -> (speakerID: String?, text: String) {
        let text = raw.trimmed
        guard !text.isEmpty else { return (nil, "") }

        let patterns = [
            #"^\s*<v\s+([^>]+)>\s*(.+?)(?:</v>)?\s*$"#,
            #"^\s*[\[(]?((?i:(?:speaker|host|guest|interviewer|interviewee|narrator|teacher|student|lecturer|instructor|professor|presenter|moderator|male|female|man|woman|nguoi noi|người nói|giang vien|giảng viên|hoc vien|học viên|khach moi|khách mời|mc))[\p{L}\p{N}\s._-]{0,24})[\])]?\s*[:：-]\s*(.+)$"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let speakerRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text)
            else { continue }

            let speaker = String(text[speakerRange])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmed
            let body = String(text[bodyRange]).trimmed
            if !speaker.isEmpty, !body.isEmpty {
                return (speaker, body)
            }
        }

        return (nil, text)
    }
}

enum TranscriptionError: LocalizedError {
    case noAudio
    case modelUnavailable
    case empty
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .noAudio:          return "That video has no audio to transcribe."
        case .modelUnavailable: return "The transcription model couldn't be loaded."
        case .empty:            return "No speech was found in that video."
        case .audioConversionFailed:
            return "Couldn't convert the audio into WAV chunks for transcription."
        }
    }
}
