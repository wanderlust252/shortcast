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
}
