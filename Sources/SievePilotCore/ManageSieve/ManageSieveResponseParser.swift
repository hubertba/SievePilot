import Foundation

public struct ManageSieveResponseParser: Sendable {
    private let limits: ManageSieveLimits
    private var buffer: [UInt8] = []
    private var aggregateByteCount = 0
    private var completedDataLineCount = 0
    private var failure: ManageSieveParserError?

    public init(limits: ManageSieveLimits = .production) {
        self.limits = limits
    }

    public mutating func feed(_ data: Data) throws -> [ManageSieveWireLine] {
        if let failure { throw failure }
        buffer.append(contentsOf: data)

        do {
            var lines: [ManageSieveWireLine] = []
            while true {
                var lineParser = LineParser(
                    bytes: buffer,
                    maximumLineLength: limits.maximumLineLength,
                    maximumLiteralLength: limits.maximumLiteralLength
                )
                guard let parsed = try lineParser.parse() else { break }
                let nextAggregateByteCount = try checkedSum(
                    aggregateByteCount,
                    parsed.consumedByteCount,
                    error: .aggregateResponseTooLong
                )
                guard nextAggregateByteCount <= limits.maximumAggregateResponseLength else {
                    throw ManageSieveParserError.aggregateResponseTooLong
                }

                if parsed.line.isTerminalStatus {
                    aggregateByteCount = 0
                    completedDataLineCount = 0
                } else {
                    let nextLineCount = try checkedSum(
                        completedDataLineCount,
                        1,
                        error: .tooManyLines
                    )
                    guard nextLineCount <= limits.maximumLineCount else {
                        throw ManageSieveParserError.tooManyLines
                    }
                    aggregateByteCount = nextAggregateByteCount
                    completedDataLineCount = nextLineCount
                }

                buffer.removeFirst(parsed.consumedByteCount)
                lines.append(parsed.line)
            }

            let bufferedAggregateByteCount = try checkedSum(
                aggregateByteCount,
                buffer.count,
                error: .aggregateResponseTooLong
            )
            guard bufferedAggregateByteCount <= limits.maximumAggregateResponseLength else {
                throw ManageSieveParserError.aggregateResponseTooLong
            }
            return lines
        } catch let error as ManageSieveParserError {
            failure = error
            throw error
        }
    }

    public mutating func finish() throws {
        if let failure { throw failure }
        guard buffer.isEmpty, aggregateByteCount == 0, completedDataLineCount == 0 else {
            failure = .incompleteInput
            throw ManageSieveParserError.incompleteInput
        }
    }

    private func checkedSum(
        _ lhs: Int,
        _ rhs: Int,
        error: ManageSieveParserError
    ) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw error }
        return sum
    }
}

private struct LineParser {
    let bytes: [UInt8]
    let maximumLineLength: Int
    let maximumLiteralLength: Int

    private var cursor = 0
    private var syntaxByteCount = 0

    init(bytes: [UInt8], maximumLineLength: Int, maximumLiteralLength: Int) {
        self.bytes = bytes
        self.maximumLineLength = maximumLineLength
        self.maximumLiteralLength = maximumLiteralLength
    }

    mutating func parse() throws -> ParsedLine? {
        do {
            var tokens: [ManageSieveToken] = []
            tokens.append(try parseToken())

            while true {
                guard cursor < bytes.count else { throw IncompleteParse() }
                switch bytes[cursor] {
                case 0x20:
                    repeat {
                        try consumeSyntaxByte()
                    } while cursor < bytes.count && bytes[cursor] == 0x20
                    guard cursor < bytes.count else { throw IncompleteParse() }
                    guard bytes[cursor] != 0x0d else {
                        throw ManageSieveParserError.malformedSyntax
                    }
                    tokens.append(try parseToken())
                case 0x0d:
                    try consumeCRLF()
                    return ParsedLine(
                        line: ManageSieveWireLine(tokens: normalizeStatus(in: tokens)),
                        consumedByteCount: cursor
                    )
                case 0x0a:
                    throw ManageSieveParserError.bareLineFeed
                default:
                    throw ManageSieveParserError.malformedSyntax
                }
            }
        } catch is IncompleteParse {
            return nil
        }
    }

    private mutating func parseToken() throws -> ManageSieveToken {
        guard cursor < bytes.count else { throw IncompleteParse() }
        switch bytes[cursor] {
        case 0x22:
            return try parseQuotedString()
        case 0x28:
            return try parseList()
        case 0x7b:
            return try parseLiteral()
        case 0x0a:
            throw ManageSieveParserError.bareLineFeed
        default:
            return try parseAtomOrNumber()
        }
    }

    private mutating func parseQuotedString() throws -> ManageSieveToken {
        try consumeSyntaxByte()
        var value: [UInt8] = []

        while true {
            guard cursor < bytes.count else { throw IncompleteParse() }
            switch bytes[cursor] {
            case 0x22:
                try consumeSyntaxByte()
                return .string(Data(value))
            case 0x5c:
                try consumeSyntaxByte()
                guard cursor < bytes.count else { throw IncompleteParse() }
                let escaped = bytes[cursor]
                guard escaped == 0x22 || escaped == 0x5c else {
                    throw ManageSieveParserError.malformedEscape
                }
                value.append(escaped)
                try consumeSyntaxByte()
            case 0x0a:
                throw ManageSieveParserError.bareLineFeed
            case 0x0d, 0x00:
                throw ManageSieveParserError.malformedSyntax
            default:
                guard (0x01...0x7f).contains(bytes[cursor]) else {
                    throw ManageSieveParserError.malformedSyntax
                }
                value.append(bytes[cursor])
                try consumeSyntaxByte()
            }
        }
    }

    private mutating func parseList() throws -> ManageSieveToken {
        try consumeSyntaxByte()
        var tokens: [ManageSieveToken] = []

        guard cursor < bytes.count else { throw IncompleteParse() }
        if bytes[cursor] == 0x29 {
            try consumeSyntaxByte()
            return .list(tokens)
        }

        while true {
            tokens.append(try parseToken())
            guard cursor < bytes.count else { throw IncompleteParse() }

            switch bytes[cursor] {
            case 0x20:
                repeat {
                    try consumeSyntaxByte()
                } while cursor < bytes.count && bytes[cursor] == 0x20
                guard cursor < bytes.count else { throw IncompleteParse() }
                guard bytes[cursor] != 0x29 else {
                    throw ManageSieveParserError.malformedSyntax
                }
            case 0x29:
                try consumeSyntaxByte()
                return .list(tokens)
            case 0x0a:
                throw ManageSieveParserError.bareLineFeed
            case 0x0d:
                if cursor + 1 >= bytes.count { throw IncompleteParse() }
                throw ManageSieveParserError.malformedSyntax
            default:
                throw ManageSieveParserError.malformedSyntax
            }
        }
    }

    private mutating func parseLiteral() throws -> ManageSieveToken {
        try consumeSyntaxByte()
        guard cursor < bytes.count else { throw IncompleteParse() }
        guard isDigit(bytes[cursor]) else {
            throw ManageSieveParserError.invalidLiteralLength
        }

        let firstDigit = bytes[cursor]
        var digitCount = 0
        var length: UInt32 = 0
        while true {
            guard cursor < bytes.count else { throw IncompleteParse() }
            let byte = bytes[cursor]
            guard isDigit(byte) else { break }

            if firstDigit == 0x30, digitCount > 0 {
                throw ManageSieveParserError.invalidLiteralLength
            }
            let digit = UInt32(byte - 0x30)
            let (multiplied, multiplicationOverflow) = length.multipliedReportingOverflow(by: 10)
            let (updated, additionOverflow) = multiplied.addingReportingOverflow(digit)
            guard !multiplicationOverflow, !additionOverflow else {
                throw ManageSieveParserError.invalidLiteralLength
            }
            length = updated
            digitCount += 1
            try consumeSyntaxByte()
        }

        guard cursor < bytes.count else { throw IncompleteParse() }
        if bytes[cursor] == 0x2b {
            throw ManageSieveParserError.nonSynchronizingLiteral
        }
        guard bytes[cursor] == 0x7d else {
            throw ManageSieveParserError.invalidLiteralLength
        }
        try consumeSyntaxByte()

        guard Int(length) <= maximumLiteralLength else {
            throw ManageSieveParserError.literalTooLong
        }
        try consumeCRLF()

        let literalLength = Int(length)
        guard literalLength <= bytes.count - cursor else { throw IncompleteParse() }
        let literal = Data(bytes[cursor..<(cursor + literalLength)])
        cursor += literalLength
        return .string(literal)
    }

    private mutating func parseAtomOrNumber() throws -> ManageSieveToken {
        let start = cursor
        while cursor < bytes.count, isAtomByte(bytes[cursor]) {
            try consumeSyntaxByte()
        }
        guard cursor > start else { throw ManageSieveParserError.malformedSyntax }

        let atomBytes = bytes[start..<cursor]
        if atomBytes.allSatisfy(isDigit) {
            var value: UInt32 = 0
            for byte in atomBytes {
                let (multiplied, multiplicationOverflow) = value.multipliedReportingOverflow(by: 10)
                let (updated, additionOverflow) = multiplied.addingReportingOverflow(UInt32(byte - 0x30))
                guard !multiplicationOverflow, !additionOverflow else {
                    throw ManageSieveParserError.malformedSyntax
                }
                value = updated
            }
            return .number(value)
        }
        return .atom(String(decoding: atomBytes, as: UTF8.self))
    }

    private mutating func consumeSyntaxByte() throws {
        let (nextCount, overflow) = syntaxByteCount.addingReportingOverflow(1)
        guard !overflow, nextCount <= maximumLineLength else {
            throw ManageSieveParserError.lineTooLong
        }
        syntaxByteCount = nextCount
        cursor += 1
    }

    private mutating func consumeCRLF() throws {
        guard cursor < bytes.count else { throw IncompleteParse() }
        guard bytes[cursor] == 0x0d else {
            if bytes[cursor] == 0x0a { throw ManageSieveParserError.bareLineFeed }
            throw ManageSieveParserError.malformedSyntax
        }
        guard cursor + 1 < bytes.count else { throw IncompleteParse() }
        guard bytes[cursor + 1] == 0x0a else {
            throw ManageSieveParserError.malformedSyntax
        }
        cursor += 2
    }

    private func normalizeStatus(in tokens: [ManageSieveToken]) -> [ManageSieveToken] {
        guard case let .atom(atom)? = tokens.first else { return tokens }
        let normalized = atom.uppercased()
        guard normalized == "OK" || normalized == "NO" || normalized == "BYE" else { return tokens }

        var result = tokens
        result[0] = .atom(normalized)
        return result
    }

    private func isAtomByte(_ byte: UInt8) -> Bool {
        guard (0x21...0x7e).contains(byte) else { return false }
        return ![0x22, 0x25, 0x28, 0x29, 0x2a, 0x5c, 0x7b].contains(byte)
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}

private struct ParsedLine {
    let line: ManageSieveWireLine
    let consumedByteCount: Int
}

private struct IncompleteParse: Error {}

private extension ManageSieveWireLine {
    var isTerminalStatus: Bool {
        guard case let .atom(atom)? = tokens.first else { return false }
        return atom == "OK" || atom == "NO" || atom == "BYE"
    }
}
