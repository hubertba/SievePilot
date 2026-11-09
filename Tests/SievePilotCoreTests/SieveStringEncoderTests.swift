import Foundation
import Testing
@testable import SievePilotCore

@Suite struct SieveStringEncoderTests {
    @Test func testEscapesQuoteAndBackslash() throws {
        let encoded = try SieveStringEncoder.encodeQuoted("a\"b\\c")

        #expect(encoded == Data("\"a\\\"b\\\\c\"".utf8))
    }

    @Test func testRejectsNULInQuotedString() {
        #expect(throws: SieveStringEncodingError.unsupportedControlCharacter) {
            try SieveStringEncoder.encodeQuoted("before\0after")
        }
    }

    @Test func testMessageQuotedStringPreservesLineBreaks() throws {
        let encoded = try SieveStringEncoder.encodeMessageQuoted("before\nafter\r\n")

        #expect(encoded == Data("\"before\nafter\r\n\"".utf8))
    }
}
