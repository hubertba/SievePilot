import Foundation

public struct SievePreamble: Equatable, Sendable {
    public let insertionOffset: Int
    public let preferredLineEnding: LineEnding
    public let hasUTF8BOM: Bool

    public init(insertionOffset: Int, preferredLineEnding: LineEnding, hasUTF8BOM: Bool) {
        self.insertionOffset = insertionOffset
        self.preferredLineEnding = preferredLineEnding
        self.hasUTF8BOM = hasUTF8BOM
    }
}

public enum SievePreambleError: Error, Equatable, Sendable {
    case malformedString
    case malformedMultilineLiteral
    case malformedRequire
    case unsupportedLeadingSyntax
}

public enum SievePreambleScanner {
    public static func scan(_ script: Data) throws -> SievePreamble {
        let lexer = SieveByteLexer(data: script)
        let hasBOM = lexer.bytes.starts(with: [0xef, 0xbb, 0xbf])
        var index = hasBOM ? 3 : 0
        index = try lexer.skipTrivia(from: index)

        while index < lexer.bytes.count {
            let commandStart = index
            guard let (identifier, afterIdentifier) = lexer.readIdentifier(from: index) else {
                if lexer.bytes[index] == 0x22 {
                    _ = try lexer.skipQuotedString(from: index)
                    throw SievePreambleError.unsupportedLeadingSyntax
                }
                if lexer.hasASCII("text:", at: index) {
                    _ = try lexer.skipMultilineLiteral(from: index)
                    throw SievePreambleError.unsupportedLeadingSyntax
                }
                return SievePreamble(
                    insertionOffset: commandStart,
                    preferredLineEnding: lexer.preferredLineEnding,
                    hasUTF8BOM: hasBOM
                )
            }

            guard identifier.lowercased() == "require" else {
                return SievePreamble(
                    insertionOffset: commandStart,
                    preferredLineEnding: lexer.preferredLineEnding,
                    hasUTF8BOM: hasBOM
                )
            }

            do {
                index = try lexer.parseRequireArgument(from: afterIdentifier)
                index = try lexer.skipTrivia(from: index)
                guard index < lexer.bytes.count, lexer.bytes[index] == 0x3b else {
                    throw SievePreambleError.malformedRequire
                }
                index = try lexer.skipTrivia(from: index + 1)
            } catch let error as SievePreambleError {
                throw error
            } catch {
                throw SievePreambleError.malformedRequire
            }
        }

        return SievePreamble(
            insertionOffset: index,
            preferredLineEnding: lexer.preferredLineEnding,
            hasUTF8BOM: hasBOM
        )
    }
}

struct SieveByteLexer {
    let bytes: [UInt8]

    init(data: Data) {
        bytes = Array(data)
    }

    var preferredLineEnding: LineEnding {
        for index in bytes.indices where bytes[index] == 0x0a {
            return index > 0 && bytes[index - 1] == 0x0d ? .crlf : .lf
        }
        return .lf
    }

    func skipTrivia(from start: Int) throws -> Int {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case 0x09, 0x0a, 0x0c, 0x0d, 0x20:
                index += 1
            case 0x23:
                if isReservedMarkerLine(at: index) { return index }
                index += 1
                while index < bytes.count, bytes[index] != 0x0a { index += 1 }
                if index < bytes.count { index += 1 }
            case 0x2f where index + 1 < bytes.count && bytes[index + 1] == 0x2a:
                guard let end = blockCommentEnd(from: index + 2) else {
                    throw SievePreambleError.unsupportedLeadingSyntax
                }
                index = end
            default:
                return index
            }
        }
        return index
    }

    func readIdentifier(from start: Int) -> (String, Int)? {
        guard start < bytes.count, isIdentifierStart(bytes[start]) else { return nil }
        var index = start + 1
        while index < bytes.count, isIdentifierContinuation(bytes[index]) { index += 1 }
        return (String(decoding: bytes[start..<index], as: UTF8.self), index)
    }

    func parseRequireArgument(from start: Int) throws -> Int {
        var index = try skipTrivia(from: start)
        guard index < bytes.count else { throw SievePreambleError.malformedRequire }

        if bytes[index] == 0x5b {
            index = try skipTrivia(from: index + 1)
            var parsedAny = false
            while index < bytes.count, bytes[index] != 0x5d {
                index = try skipString(from: index)
                parsedAny = true
                index = try skipTrivia(from: index)
                if index < bytes.count, bytes[index] == 0x2c {
                    index = try skipTrivia(from: index + 1)
                } else if index < bytes.count, bytes[index] != 0x5d {
                    throw SievePreambleError.malformedRequire
                }
            }
            guard parsedAny, index < bytes.count, bytes[index] == 0x5d else {
                throw SievePreambleError.malformedRequire
            }
            return index + 1
        }

        return try skipString(from: index)
    }

    func skipString(from start: Int) throws -> Int {
        guard start < bytes.count else { throw SievePreambleError.malformedString }
        if bytes[start] == 0x22 {
            return try skipQuotedString(from: start)
        }
        if hasASCII("text:", at: start) {
            return try skipMultilineLiteral(from: start)
        }
        throw SievePreambleError.malformedRequire
    }

    func skipQuotedString(from start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                return index + 1
            case 0x5c:
                index += 2
            default:
                index += 1
            }
        }
        throw SievePreambleError.malformedString
    }

    func skipMultilineLiteral(from start: Int) throws -> Int {
        var index = start + 5
        while index < bytes.count, bytes[index] != 0x0a { index += 1 }
        guard index < bytes.count else { throw SievePreambleError.malformedMultilineLiteral }
        index += 1

        while index <= bytes.count {
            let lineStart = index
            while index < bytes.count, bytes[index] != 0x0a { index += 1 }
            var lineEnd = index
            if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0d { lineEnd -= 1 }
            if lineEnd - lineStart == 1, bytes[lineStart] == 0x2e {
                return index < bytes.count ? index + 1 : index
            }
            guard index < bytes.count else { break }
            index += 1
        }
        throw SievePreambleError.malformedMultilineLiteral
    }

    func hasASCII(_ value: String, at start: Int) -> Bool {
        let expected = Array(value.utf8)
        guard start + expected.count <= bytes.count else { return false }
        return zip(bytes[start..<(start + expected.count)], expected).allSatisfy {
            asciiLowercased($0.0) == asciiLowercased($0.1)
        }
    }

    private func isReservedMarkerLine(at index: Int) -> Bool {
        guard hasASCII("# BEGIN SIEVEPILOT", at: index)
                || hasASCII("# END SIEVEPILOT", at: index) else {
            return false
        }
        var lineStart = index
        while lineStart > 0, bytes[lineStart - 1] != 0x0a { lineStart -= 1 }
        return bytes[lineStart..<index].allSatisfy { $0 == 0x09 || $0 == 0x20 || $0 == 0x0d }
    }

    private func blockCommentEnd(from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x2a, bytes[index + 1] == 0x2f {
                return index + 2
            }
            index += 1
        }
        return nil
    }

    private func isIdentifierStart(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (0x30...0x39).contains(byte) || byte == 0x2d || byte == 0x5f
    }

    private func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5a).contains(byte) ? byte + 0x20 : byte
    }
}
