import XCTest
@testable import Concept2_SDK

final class CSAFEFrameTests: XCTestCase {
    func testBuildsTheDocumentsStrokeStateRequest() {
        // "F1 1A 01 BF A4 F2" in the Concept2 CSAFE document: the PM-specific wrapper asking for the stroke state.
        XCTAssertEqual([UInt8](CSAFEFrame.pmFrame([[0xBF]])), [0xF1, 0x1A, 0x01, 0xBF, 0xA4, 0xF2])
    }

    func testBuildsTheDocumentsForcePlotRequest() {
        // "F1 1A 03 6B 01 14 67 F2": read 20 bytes of force plot data.
        XCTAssertEqual([UInt8](CSAFEFrame.pmFrame([[0x6B, 0x01, 0x14]])), [0xF1, 0x1A, 0x03, 0x6B, 0x01, 0x14, 0x67, 0xF2])
    }

    func testStuffsBytesThatLookLikeFlags() {
        XCTAssertEqual([UInt8](CSAFEFrame.frame([0xF1])), [0xF1, 0xF3, 0x01, 0xF3, 0x01, 0xF2])
        let contents: [UInt8] = [0x01, 0xF0, 0xF2, 0xF3, 0x05]
        let parsed = CSAFEFrame.parse([UInt8](CSAFEFrame.frame([0x09, 0xAA, 0x04] + contents)))
        XCTAssertEqual(parsed?.commands[0xAA], contents[0..<3].map { $0 } + [0xF3])
    }

    func testReadsResponsesInsideTheWrapper() {
        let frame = CSAFEFrame.frame([0x01, 0x1A, 0x0A, 0xBF, 0x01, 0x04, 0xA0, 0x05, 0x00, 0x00, 0x01, 0x2C, 0x05])
        let response = CSAFEFrame.parse([UInt8](frame))
        XCTAssertEqual(response?.status, 0x01)
        XCTAssertEqual(response?.commands[0xBF], [0x04])
        XCTAssertEqual(response?.commands[0xA0], [0x00, 0x00, 0x01, 0x2C, 0x05])
        XCTAssertEqual(CSAFEFrame.value([0x00, 0x00, 0x01, 0x2C]), 300)
    }

    func testRejectsABadChecksum() {
        var bytes = [UInt8](CSAFEFrame.pmFrame([[0xBF]]))
        bytes[4] ^= 0x01
        XCTAssertNil(CSAFEFrame.parse(bytes))
    }

    func testFindsAFrameAfterAReportID() {
        let bytes: [UInt8] = [0x02] + [UInt8](CSAFEFrame.frame([0x01, 0x1A, 0x03, 0xBF, 0x01, 0x02])) + [0x00, 0x00]
        XCTAssertEqual(CSAFEFrame.parse(bytes)?.commands[0xBF], [0x02])
    }
}
