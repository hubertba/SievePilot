import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManageSieveResponseParserTests {
    @Test func fragmentedQuotedAndStatusLinesMatchUnfragmentedParsing() throws {
        let wire = Data("\"IMPLEMENTATION\" \"Dovecot Pigeonhole\"\r\nOK \"ready\"\r\n".utf8)
        let expected = [
            ManageSieveWireLine(tokens: [
                .string(Data("IMPLEMENTATION".utf8)),
                .string(Data("Dovecot Pigeonhole".utf8)),
            ]),
            ManageSieveWireLine(tokens: [
                .atom("OK"),
                .string(Data("ready".utf8)),
            ]),
        ]

        try expectEverySplit(of: wire, produces: expected)
    }

    @Test func fragmentedQuotedEscapesPreserveDecodedBytes() throws {
        let wire = Data("\"escaped \\\" quote\" \"escaped \\\\ slash\"\r\nok\r\n".utf8)
        let expected = [
            ManageSieveWireLine(tokens: [
                .string(Data("escaped \" quote".utf8)),
                .string(Data("escaped \\ slash".utf8)),
            ]),
            ManageSieveWireLine(tokens: [.atom("OK")]),
        ]

        try expectEverySplit(of: wire, produces: expected)
    }

    @Test func fragmentedLiteralPreservesEmbeddedCRLF() throws {
        let wire = Data("{5}\r\na\r\nbc\r\nOK\r\n".utf8)
        let expected = [
            ManageSieveWireLine(tokens: [.string(Data("a\r\nbc".utf8))]),
            ManageSieveWireLine(tokens: [.atom("OK")]),
        ]

        try expectEverySplit(of: wire, produces: expected)
    }

    @Test func literalPreservesInvalidUTF8() throws {
        var wire = Data("{3}\r\n".utf8)
        wire.append(contentsOf: [0xff, 0x00, 0xfe])
        wire.append(Data("\r\nOK\r\n".utf8))
        var parser = ManageSieveResponseParser()

        let lines = try parser.feed(wire)
        try parser.finish()

        #expect(lines == [
            ManageSieveWireLine(tokens: [.string(Data([0xff, 0x00, 0xfe]))]),
            ManageSieveWireLine(tokens: [.atom("OK")]),
        ])
    }

    @Test func invalidQuotedByteIsRejectedWhileLiteralBytesRemainOpaque() throws {
        var quotedWire = Data([0x22, 0xff, 0x22])
        quotedWire.append(Data("\r\nOK\r\n".utf8))
        var quotedParser = ManageSieveResponseParser()

        #expect(throws: ManageSieveParserError.malformedSyntax) {
            try quotedParser.feed(quotedWire)
        }

        var literalWire = Data("{1}\r\n".utf8)
        literalWire.append(0xff)
        literalWire.append(Data("\r\nOK\r\n".utf8))
        var literalParser = ManageSieveResponseParser()

        #expect(try literalParser.feed(literalWire) == [
            ManageSieveWireLine(tokens: [.string(Data([0xff]))]),
            ManageSieveWireLine(tokens: [.atom("OK")]),
        ])
        try literalParser.finish()
    }

    @Test func nestedParenthesizedTokensArePreserved() throws {
        let wire = Data("NO (WARNINGS (3 \"bad\")) \"failed\"\r\n".utf8)
        var parser = ManageSieveResponseParser()

        let lines = try parser.feed(wire)
        try parser.finish()

        #expect(lines == [
            ManageSieveWireLine(tokens: [
                .atom("NO"),
                .list([
                    .atom("WARNINGS"),
                    .list([.number(3), .string(Data("bad".utf8))]),
                ]),
                .string(Data("failed".utf8)),
            ]),
        ])
    }

    @Test(arguments: [
        (Data("{5+}\r\nabcde\r\n".utf8), ManageSieveParserError.nonSynchronizingLiteral),
        (Data("\"value\"\n".utf8), .bareLineFeed),
        (Data("\"bad\\q\"\r\n".utf8), .malformedEscape),
        (Data("{05}\r\nabcde\r\n".utf8), .invalidLiteralLength),
        (Data("{4294967296}\r\n".utf8), .invalidLiteralLength),
        (Data("\"value\"garbage\r\n".utf8), .malformedSyntax),
    ])
    func malformedInputIsRejected(input: Data, expectedError: ManageSieveParserError) {
        var parser = ManageSieveResponseParser()

        #expect(throws: expectedError) {
            try parser.feed(input)
        }
    }

    @Test(arguments: [
        Data("\"unterminated".utf8),
        Data("(CODE".utf8),
        Data("{5}\r\nabc".utf8),
        Data("OK\r".utf8),
        Data("\"data\"\r\n".utf8),
    ])
    func finishRejectsIncompleteResponses(input: Data) throws {
        var parser = ManageSieveResponseParser()
        _ = try parser.feed(input)

        #expect(throws: ManageSieveParserError.incompleteInput) {
            try parser.finish()
        }
    }

    @Test func productionLimitsUseRequiredBounds() {
        #expect(ManageSieveLimits.production == ManageSieveLimits(
            maximumLineLength: 8 * 1024,
            maximumLiteralLength: 10 * 1024 * 1024,
            maximumAggregateResponseLength: 16 * 1024 * 1024,
            maximumLineCount: 256
        ))
    }

    @Test func lineLengthAllowsExactLimitAndRejectsOneByteOver() throws {
        var exactParser = ManageSieveResponseParser(limits: limits(line: 4))
        #expect(try exactParser.feed(Data("ABCD\r\nOK\r\n".utf8)).count == 2)
        try exactParser.finish()

        var oversizedParser = ManageSieveResponseParser(limits: limits(line: 4))
        #expect(throws: ManageSieveParserError.lineTooLong) {
            try oversizedParser.feed(Data("ABCDE\r\nOK\r\n".utf8))
        }
    }

    @Test func literalLengthAllowsExactLimitAndRejectsOneByteOver() throws {
        var exactParser = ManageSieveResponseParser(limits: limits(literal: 5))
        let exactLines = try exactParser.feed(Data("{5}\r\nabcde\r\nOK\r\n".utf8))
        #expect(exactLines.first == ManageSieveWireLine(tokens: [.string(Data("abcde".utf8))]))
        try exactParser.finish()

        var oversizedParser = ManageSieveResponseParser(limits: limits(literal: 5))
        #expect(throws: ManageSieveParserError.literalTooLong) {
            try oversizedParser.feed(Data("{6}\r\nabcdef\r\nOK\r\n".utf8))
        }
    }

    @Test func aggregateLengthAllowsExactLimitAndRejectsOneByteOver() throws {
        let response = Data("\"x\"\r\nOK\r\n".utf8)
        var exactParser = ManageSieveResponseParser(limits: limits(aggregate: response.count))
        #expect(try exactParser.feed(response).count == 2)
        try exactParser.finish()

        var oversizedParser = ManageSieveResponseParser(limits: limits(aggregate: response.count - 1))
        #expect(throws: ManageSieveParserError.aggregateResponseTooLong) {
            try oversizedParser.feed(response)
        }
    }

    @Test func dataLineCountAllowsExactLimitAndRejectsOneLineOver() throws {
        var exactParser = ManageSieveResponseParser(limits: limits(lineCount: 2))
        #expect(try exactParser.feed(Data("\"a\"\r\n\"b\"\r\nOK\r\n".utf8)).count == 3)
        try exactParser.finish()

        var oversizedParser = ManageSieveResponseParser(limits: limits(lineCount: 2))
        #expect(throws: ManageSieveParserError.tooManyLines) {
            try oversizedParser.feed(Data("\"a\"\r\n\"b\"\r\n\"c\"\r\nOK\r\n".utf8))
        }
    }

    @Test(arguments: [false, true])
    func quotedStringWireLengthHasIndependentRFCBound(escaped: Bool) throws {
        let content = escaped ? String(repeating: "\\\\", count: 511) : String(repeating: "a", count: 1022)
        let exact = Data(("\"" + content + "\"\r\nOK\r\n").utf8)
        try expectEverySplit(of: exact, produces: [
            ManageSieveWireLine(tokens: [.string(Data((escaped ? String(repeating: "\\", count: 511) : content).utf8))]),
            ManageSieveWireLine(tokens: [.atom("OK")]),
        ])
        let oversized = Data(("\"" + content + "a\"\r\nOK\r\n").utf8)
        for split in [0, 1023, 1024, oversized.count] {
            var parser = ManageSieveResponseParser()
            #expect(throws: ManageSieveParserError.quotedStringTooLong) {
                _ = try parser.feed(oversized.prefix(split))
                _ = try parser.feed(oversized.dropFirst(split))
            }
        }
    }

    @Test func oversizedFeedIsBoundedAndTerminalFailureReleasesStorage() throws {
        var parser = ManageSieveResponseParser(limits: limits(line: 4096, aggregate: 32))
        #expect(throws: ManageSieveParserError.aggregateResponseTooLong) {
            try parser.feed(Data(repeating: 0x41, count: 1_000_000))
        }
        #expect(parser.peakBufferedByteCount <= 32)
        #expect(parser.bufferedByteCount == 0)
        #expect(parser.retainedBufferCapacity == 0)
        #expect(throws: ManageSieveParserError.aggregateResponseTooLong) { try parser.feed(Data("OK\r\n".utf8)) }
        #expect(parser.bufferedByteCount == 0)
        #expect(parser.retainedBufferCapacity == 0)
    }

    @Test func finishFailureReleasesIncompleteStorage() throws {
        var parser = ManageSieveResponseParser()
        _ = try parser.feed(Data("\"unfinished".utf8))
        #expect(throws: ManageSieveParserError.incompleteInput) { try parser.finish() }
        #expect(parser.bufferedByteCount == 0)
        #expect(parser.retainedBufferCapacity == 0)
    }

    @Test func boundedFeedStillAcceptsManyResponsesAndFragmentedSuffix() throws {
        var parser = ManageSieveResponseParser(limits: limits(aggregate: 9))
        let response = "\"x\"\r\nOK\r\n"
        #expect(try parser.feed(Data((String(repeating: response, count: 1000) + "\"x").utf8)).count == 2000)
        #expect(try parser.feed(Data("\"\r\nOK\r\n".utf8)).count == 2)
        try parser.finish()
    }

    private func expectEverySplit(
        of wire: Data,
        produces expected: [ManageSieveWireLine],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for split in 0...wire.count {
            var parser = ManageSieveResponseParser()
            var lines = try parser.feed(wire.prefix(split))
            lines.append(contentsOf: try parser.feed(wire.dropFirst(split)))
            try parser.finish()

            #expect(lines == expected, "Mismatch at split point \(split)", sourceLocation: sourceLocation)
        }
    }

    private func limits(
        line: Int = 1_024,
        literal: Int = 1_024,
        aggregate: Int = 4_096,
        lineCount: Int = 16
    ) -> ManageSieveLimits {
        ManageSieveLimits(
            maximumLineLength: line,
            maximumLiteralLength: literal,
            maximumAggregateResponseLength: aggregate,
            maximumLineCount: lineCount
        )
    }
}
