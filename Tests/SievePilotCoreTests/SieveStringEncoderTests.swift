import Foundation
import Testing
@testable import SievePilotCore

@Suite struct SieveStringEncoderTests {
    @Test func testEscapesQuoteAndBackslash() throws {
        let encoded = try SieveStringEncoder.encodeQuoted("a\"b\\c")

        #expect(encoded == Data("\"a\\\"b\\\\c\"".utf8))
    }

    @Test func testRejectsNULAndNewlineInQuotedString() {
        #expect(throws: SieveStringEncodingError.unsupportedControlCharacter) {
            try SieveStringEncoder.encodeQuoted("before\0after")
        }
        #expect(throws: SieveStringEncodingError.unsupportedControlCharacter) {
            try SieveStringEncoder.encodeQuoted("before\nafter")
        }
    }
}
