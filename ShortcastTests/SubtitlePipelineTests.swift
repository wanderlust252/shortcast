import XCTest
@testable import Shortcast

final class SubtitlePipelineTests: XCTestCase {
    func testFormatterKeepsShortVietnameseSubtitleWithinTwoReadableLines() {
        let text = "Đây là cách mô hình giữ ngữ cảnh mà không làm phụ đề quá dài."

        let display = SubtitleFormatter.displayText(text)
        let lines = display.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertLessThanOrEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.count <= SubtitleFormatter.targetCharactersPerLine })
    }

    func testFormatterRequestsRepairWhenCueCannotFitTargetLines() {
        let text = "Đây là một câu phụ đề rất dài với nhiều chi tiết liên tiếp khiến người xem khó đọc kịp nếu giữ nguyên trong hai dòng ngắn."

        XCTAssertTrue(SubtitleFormatter.needsRepair(text))
    }

    @MainActor
    func testSRTParserCapturesKnownSpeakerPrefixWithoutRenderingItAsText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-speaker-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        1
        00:00:01,000 --> 00:00:03,000
        Speaker 1: Hello from the first speaker.

        2
        00:00:03,000 --> 00:00:05,000
        Speaker 2: Reply from the second speaker.
        """.write(to: url, atomically: true, encoding: .utf8)

        let transcript = try XCTUnwrap(TranscriptionService.parseSubtitles(at: url))

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].speakerID, "Speaker 1")
        XCTAssertEqual(transcript.segments[0].text, "Hello from the first speaker.")
        XCTAssertTrue(transcript.srtLike().contains("Speaker 2: Reply from the second speaker."))
    }

    func testTranslatedVideoExportsRenderedSubtitleTimelineWithoutIntroOffset() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 1.25, end: 3.5, text: "Xin chào thế giới."),
                TranscriptSegment(start: 61.0, end: 64.25, text: "Đây là phụ đề đã dịch."),
            ],
            language: "vi")
        let video = TranslatedVideo(
            url: URL(fileURLWithPath: "/tmp/translated.mp4"),
            renderedTranscript: transcript,
            durationSeconds: 70,
            aspectMode: .original)

        let srt = try XCTUnwrap(video.renderedSRT())

        XCTAssertTrue(srt.contains("00:00:01,250 --> 00:00:03,500"))
        XCTAssertTrue(srt.contains("00:01:01,000 --> 00:01:04,250"))
        XCTAssertFalse(srt.contains("00:00:04,250 --> 00:00:06,500"))
    }

    func testPendingFullVideoReviewExportsEditedRenderedSubtitles() throws {
        let source = Transcript(
            segments: [
                TranscriptSegment(start: 2.0, end: 4.0, text: "Today we use cloud code."),
            ],
            language: "en")
        let rendered = Transcript(
            segments: [
                TranscriptSegment(start: 2.0, end: 4.0, text: "Hôm nay ta dùng cloud code."),
            ],
            language: "vi")
        var review = PendingSubtitleReview(
            mode: .fullVideo,
            sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            sourceFileName: "source.mp4",
            sourceDurationSeconds: 10,
            plan: nil,
            sourceTranscript: source,
            renderedTranscript: rendered,
            aspectMode: .original,
            showIntroCard: false,
            exportQuality: .automatic)

        review.updateRenderedText(at: 0, text: "Hôm nay ta dùng Claude Code.")
        let srt = try XCTUnwrap(review.renderedSRT())

        XCTAssertTrue(srt.contains("00:00:02,000 --> 00:00:04,000"))
        XCTAssertTrue(srt.contains("Claude Code"))
        XCTAssertFalse(srt.contains("cloud code"))
    }

    func testPendingFullVideoReviewCanJoinMultipleSelectedCues() throws {
        let source = Transcript(
            segments: [
                TranscriptSegment(start: 2.0, end: 4.0, text: "Opening."),
                TranscriptSegment(start: 9.0, end: 11.0, text: "Skip this."),
                TranscriptSegment(start: 20.0, end: 24.0, text: "Best insight."),
            ],
            language: "en")
        let rendered = Transcript(
            segments: [
                TranscriptSegment(start: 2.0, end: 4.0, text: "Mở đầu."),
                TranscriptSegment(start: 9.0, end: 11.0, text: "Bỏ đoạn này."),
                TranscriptSegment(start: 20.0, end: 24.0, text: "Ý hay nhất."),
            ],
            language: "vi")
        var review = PendingSubtitleReview(
            mode: .fullVideo,
            sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            sourceFileName: "source.mp4",
            sourceDurationSeconds: 30,
            plan: nil,
            sourceTranscript: source,
            renderedTranscript: rendered,
            aspectMode: .original,
            showIntroCard: false,
            exportQuality: .automatic)

        review.setCueIncluded(at: 1, included: false)

        let plan = try XCTUnwrap(review.selectionPlan())
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].start, 2.0)
        XCTAssertEqual(plan.segments[1].start, 20.0)

        let srt = try XCTUnwrap(review.renderedSRT())
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,000"))
        XCTAssertTrue(srt.contains("00:00:02,000 --> 00:00:06,000"))
        XCTAssertTrue(srt.contains("Mở đầu."))
        XCTAssertTrue(srt.contains("Ý hay nhất."))
        XCTAssertFalse(srt.contains("Bỏ đoạn này."))
    }

    func testPendingFullVideoReviewCanDeselectAllThenChooseCues() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 1.0, end: 3.0, text: "Đoạn một."),
                TranscriptSegment(start: 8.0, end: 10.0, text: "Đoạn hai."),
            ],
            language: "vi")
        var review = PendingSubtitleReview(
            mode: .fullVideo,
            sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            sourceFileName: "source.mp4",
            sourceDurationSeconds: 12,
            plan: nil,
            sourceTranscript: transcript,
            renderedTranscript: transcript,
            aspectMode: .original,
            showIntroCard: false,
            exportQuality: .automatic)

        review.deselectAllCues()

        XCTAssertEqual(review.cueCount, 0)
        XCTAssertNil(review.renderedSRT())

        review.setCueIncluded(at: 1, included: true)

        XCTAssertEqual(review.cueCount, 1)
        let srt = try XCTUnwrap(review.renderedSRT())
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,000"))
        XCTAssertTrue(srt.contains("Đoạn hai."))
        XCTAssertFalse(srt.contains("Đoạn một."))
    }

    func testPendingHighlightReviewExportsOutputTimelineWithIntroOffset() throws {
        let plan = HighlightPlan(
            title: "Demo",
            summary: "",
            segments: [
                HighlightSegment(start: 10.0, end: 20.0, title: "Part 1", why: ""),
            ])
        let source = Transcript(
            segments: [
                TranscriptSegment(start: 12.0, end: 14.0, text: "We use Claude Code."),
            ],
            language: "en")
        let rendered = Transcript(
            segments: [
                TranscriptSegment(start: 12.0, end: 14.0, text: "Ta dùng Claude Code."),
            ],
            language: "vi")
        let review = PendingSubtitleReview(
            mode: .highlight,
            sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            sourceFileName: "source.mp4",
            sourceDurationSeconds: 30,
            plan: plan,
            sourceTranscript: source,
            renderedTranscript: rendered,
            aspectMode: .vertical,
            showIntroCard: true,
            exportQuality: .automatic)

        let srt = try XCTUnwrap(review.renderedSRT())

        XCTAssertTrue(srt.contains("00:00:05,000 --> 00:00:07,000"))
        XCTAssertTrue(srt.contains("Ta dùng Claude Code."))
    }
}
