import Foundation
import Testing
@testable import SievePilotCore

@Suite struct SievePreambleScannerTests {
    @Test func testEmptyScriptInsertsAtZero() throws {
        let preamble = try SievePreambleScanner.scan(Data())

        #expect(preamble.insertionOffset == 0)
        #expect(preamble.preferredLineEnding == .lf)
        #expect(!preamble.hasUTF8BOM)
    }

    @Test func testInsertionFollowsBOMCommentsAndMultipleRequires() throws {
        var script = Data([0xef, 0xbb, 0xbf])
        script.append(Data("# setup\nrequire \"fileinto\";\nrequire [\"vacation\", \"date\"];\n# user rule\nfileinto \"INBOX\";\n".utf8))

        let preamble = try SievePreambleScanner.scan(script)
        let expected = script.range(of: Data("fileinto \"INBOX\"".utf8))!.lowerBound

        #expect(preamble.insertionOffset == expected)
        #expect(preamble.hasUTF8BOM)
    }

    @Test func testCommentsBetweenRequiresDoNotEndPreamble() throws {
        let script = Data("require \"fileinto\"; /* shared */\n# next\nrequire \"vacation\";\nkeep;\n".utf8)

        let preamble = try SievePreambleScanner.scan(script)

        #expect(preamble.insertionOffset == script.range(of: Data("keep;".utf8))!.lowerBound)
    }

    @Test func testRequireTextInsideQuotedStringIsIgnored() throws {
        let script = Data("if header :contains \"subject\" \"require vacation\" { keep; }\n".utf8)

        let preamble = try SievePreambleScanner.scan(script)

        #expect(preamble.insertionOffset == 0)
    }

    @Test func testRequireTextInsideMultilineLiteralIsIgnored() throws {
        let script = Data("vacation text:\nrequire [\"date\"];\n.\n;\n".utf8)

        let preamble = try SievePreambleScanner.scan(script)

        #expect(preamble.insertionOffset == 0)
    }

    @Test func testDetectsCRLFPreference() throws {
        let script = Data("require \"vacation\";\r\nkeep;\r\n".utf8)

        let preamble = try SievePreambleScanner.scan(script)

        #expect(preamble.preferredLineEnding == .crlf)
        #expect(preamble.insertionOffset == script.range(of: Data("keep;".utf8))!.lowerBound)
    }

    @Test func testMalformedLeadingStringFailsClosed() {
        let script = Data("require \"vacation;".utf8)

        #expect(throws: SievePreambleError.malformedString) {
            try SievePreambleScanner.scan(script)
        }
    }

    @Test func testInvalidUTF8OutsideRecognizedASCIITokensDoesNotFail() throws {
        let script = Data([0xff, 0xfe, 0x3b, 0x0a])

        let preamble = try SievePreambleScanner.scan(script)

        #expect(preamble.insertionOffset == 0)
    }
}
