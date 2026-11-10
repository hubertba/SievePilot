import Foundation

public enum ManageSieveToken: Equatable, Sendable {
    case atom(String)
    case number(UInt32)
    case string(Data)
    case list([ManageSieveToken])
}

public struct ManageSieveWireLine: Equatable, Sendable {
    public let tokens: [ManageSieveToken]

    public init(tokens: [ManageSieveToken]) {
        self.tokens = tokens
    }
}

public enum ManageSieveParserError: Error, Equatable, Sendable {
    case aggregateResponseTooLong
    case bareLineFeed
    case incompleteInput
    case invalidLiteralLength
    case quotedStringTooLong
    case lineTooLong
    case malformedEscape
    case malformedSyntax
    case nonSynchronizingLiteral
    case tooManyLines
    case literalTooLong
}
