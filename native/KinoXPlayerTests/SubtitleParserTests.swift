import Foundation
import XCTest
@testable import KinoXPlayer

final class SubtitleParserTests: XCTestCase {
    func testParsesSRTTimestampsAndMultilineCues() throws {
        let source = """
        1
        00:00:01,250 --> 00:00:03,500
        Hello
        world

        2
        00:01:02,000 --> 00:01:04,000
        Second
        """

        let parsed = try SubtitleParser.parse(data: Data(source.utf8))

        XCTAssertEqual(parsed.encodingName, "UTF-8")
        XCTAssertEqual(parsed.cues, [
            SubtitleCue(start: 1.25, end: 3.5, text: "Hello\nworld"),
            SubtitleCue(start: 62, end: 64, text: "Second")
        ])
    }

    func testParsesBasicWebVTTAndCleansFormatting() throws {
        let source = """
        WEBVTT

        intro
        00:01.000 --> 00:02.500 position:50%
        <i>Hello</i><br>world &amp; &#x1F44B; {\\an8}
        """

        let parsed = try SubtitleParser.parse(data: Data(source.utf8))

        XCTAssertEqual(parsed.cues, [
            SubtitleCue(start: 1, end: 2.5, text: "Hello\nworld & 👋")
        ])
    }

    func testIgnoresMalformedEmptyAndBackwardsCues() throws {
        let source = """
        1
        not a timestamp
        Nope

        2
        00:00:02,000 --> 00:00:01,000
        Backwards

        3
        00:00:03,000 --> 00:00:04,000
        <i></i>
        """

        XCTAssertEqual(try SubtitleParser.parse(data: Data(source.utf8)).cues, [])
    }

    func testDetectsUTF8BOMAndUTF16ByteOrderMarks() throws {
        let source = "1\n00:00:01,000 --> 00:00:02,000\nПривет"
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
        let utf16LE = Data([0xFF, 0xFE]) + (try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        let utf16BE = Data([0xFE, 0xFF]) + (try XCTUnwrap(source.data(using: .utf16BigEndian)))

        let utf8Result = try SubtitleParser.parse(data: utf8)
        let littleEndianResult = try SubtitleParser.parse(data: utf16LE)
        let bigEndianResult = try SubtitleParser.parse(data: utf16BE)

        XCTAssertEqual(utf8Result.encodingName, "UTF-8")
        XCTAssertEqual(littleEndianResult.encodingName, "UTF-16LE")
        XCTAssertEqual(bigEndianResult.encodingName, "UTF-16BE")
        XCTAssertEqual(utf8Result.cues, littleEndianResult.cues)
        XCTAssertEqual(utf8Result.cues, bigEndianResult.cues)
    }

    func testDetectsUTF16WithoutByteOrderMark() throws {
        let source = "1\n00:00:01,000 --> 00:00:02,000\nПривет"
        let littleEndian = try XCTUnwrap(source.data(using: .utf16LittleEndian))
        let bigEndian = try XCTUnwrap(source.data(using: .utf16BigEndian))

        let littleEndianResult = try SubtitleParser.parse(data: littleEndian)
        let bigEndianResult = try SubtitleParser.parse(data: bigEndian)

        XCTAssertEqual(littleEndianResult.encodingName, "UTF-16LE")
        XCTAssertEqual(bigEndianResult.encodingName, "UTF-16BE")
        XCTAssertEqual(littleEndianResult.cues.first?.text, "Привет")
        XCTAssertEqual(bigEndianResult.cues.first?.text, "Привет")
    }

    func testDetectsWindows1251AndWindows1252Fallbacks() throws {
        let prefix = Array("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        let windows1251 = Data(prefix + [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])
        let windows1252 = Data(prefix + [0x54, 0xFC, 0x72])

        let russian = try SubtitleParser.parse(data: windows1251)
        let german = try SubtitleParser.parse(data: windows1252)

        XCTAssertEqual(russian.encodingName, "windows-1251")
        XCTAssertEqual(russian.cues.first?.text, "Привет")
        XCTAssertEqual(german.encodingName, "windows-1252")
        XCTAssertEqual(german.cues.first?.text, "Tür")
    }

    func testDetectsVeryShortWindows1251Cue() throws {
        let prefix = Array("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        let windows1251 = Data(prefix + [0xC4, 0xE0])

        let parsed = try SubtitleParser.parse(data: windows1251)

        XCTAssertEqual(parsed.encodingName, "windows-1251")
        XCTAssertEqual(parsed.cues.first?.text, "Да")
    }

    func testReturnsAllOverlappingCuesAndAppliesOffset() {
        let cues = [
            SubtitleCue(start: 1, end: 5, text: "First"),
            SubtitleCue(start: 2, end: 4, text: "Second"),
            SubtitleCue(start: 7, end: 8, text: "Third")
        ]

        XCTAssertEqual(
            SubtitleParser.activeText(in: cues, at: 3, offset: 0),
            "First\nSecond"
        )
        XCTAssertEqual(
            SubtitleParser.activeText(in: cues, at: 4, offset: 1),
            "First\nSecond"
        )
        XCTAssertEqual(SubtitleParser.activeText(in: cues, at: 10, offset: 0), "")
    }
}
