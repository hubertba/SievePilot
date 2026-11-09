import Foundation

public struct ParsedOutOfOfficeConfiguration: Equatable, Sendable {
    public let emailAddress: String
    public let subject: String?
    public let message: String
    public let expiryInstant: Date

    public init(emailAddress: String, subject: String?, message: String, expiryInstant: Date) {
        self.emailAddress = emailAddress
        self.subject = subject
        self.message = message
        self.expiryInstant = expiryInstant
    }
}

public enum VerifiedOutOfOfficeState: Equatable, Sendable {
    case off
    case on(configuration: ParsedOutOfOfficeConfiguration)
    case expiryPassedServerClockApplies(configuration: ParsedOutOfOfficeConfiguration)
    case malformed(reason: String)
}

public enum OutOfOfficeStateEvaluator {
    public static func evaluate(activeScript: Data?, now: Date) -> VerifiedOutOfOfficeState {
        guard let activeScript else { return .off }

        do {
            let preamble = try SievePreambleScanner.scan(activeScript)
            let sections = try ManagedSectionParser.parse(activeScript, preamble: preamble)
            guard let metadataRange = sections.metadata else { return .off }
            let metadata = try ManagedScriptMetadataParser.parse(Data(activeScript[metadataRange]))
            guard
                let requirementsRange = sections.requirements,
                let ruleRange = sections.outOfOfficeRule
            else {
                return .off
            }

            try validateRequirements(Data(activeScript[requirementsRange]))
            var ruleParser = try GeneratedRuleParser(
                data: Data(activeScript[ruleRange]),
                accountID: metadata.accountID
            )
            let configuration = try ruleParser.parse()
            if now < configuration.expiryInstant {
                return .on(configuration: configuration)
            }
            return .expiryPassedServerClockApplies(configuration: configuration)
        } catch {
            return .malformed(reason: String(describing: error))
        }
    }

    private static func validateRequirements(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw RuleParseError.invalidUTF8
        }
        let newline: String
        if source.hasPrefix("# BEGIN SIEVEPILOT REQUIREMENTS v1\r\n") {
            newline = "\r\n"
        } else if source.hasPrefix("# BEGIN SIEVEPILOT REQUIREMENTS v1\n") {
            newline = "\n"
        } else {
            throw RuleParseError.invalidRequirements
        }
        let expected = [
            "# BEGIN SIEVEPILOT REQUIREMENTS v1",
            "require [\"vacation\", \"date\", \"relational\"];",
            "# END SIEVEPILOT REQUIREMENTS v1",
            ""
        ].joined(separator: newline)
        guard source == expected else { throw RuleParseError.invalidRequirements }
    }
}

private struct GeneratedRuleParser {
    let source: String
    let accountID: AccountID
    let newline: String
    var cursor: String.Index

    init(data: Data, accountID: AccountID) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw RuleParseError.invalidUTF8
        }
        let marker = "# BEGIN SIEVEPILOT RULE v1: out-of-office"
        let newline: String
        if source.hasPrefix(marker + "\r\n") {
            newline = "\r\n"
        } else if source.hasPrefix(marker + "\n") {
            newline = "\n"
        } else {
            throw RuleParseError.invalidRule
        }
        self.source = source
        self.accountID = accountID
        self.newline = newline
        cursor = source.startIndex
    }

    mutating func parse() throws -> ParsedOutOfOfficeConfiguration {
        try expect("# BEGIN SIEVEPILOT RULE v1: out-of-office" + newline)
        try expect("if currentdate :zone \"+0000\" :value \"lt\" \"iso8601\" ")
        let expiryText = try parseQuoted()
        try expect(" {" + newline)
        try expect("    vacation" + newline)
        try expect("        :addresses [")
        let emailAddress = try parseQuoted()
        try expect("]" + newline)
        try expect("        :handle ")
        let handle = try parseQuoted()
        guard handle == "sievepilot-out-of-office-\(accountID.sieveToken)" else {
            throw RuleParseError.invalidHandle
        }
        try expect(newline)

        let subject: String?
        if hasPrefix("        :subject ") {
            try expect("        :subject ")
            subject = try parseQuoted()
            try expect(newline)
        } else {
            subject = nil
        }

        try expect("        ")
        let message = try parseQuoted()
        try expect(";" + newline)
        try expect("}" + newline)
        try expect("# END SIEVEPILOT RULE v1: out-of-office" + newline)
        guard cursor == source.endIndex else { throw RuleParseError.invalidRule }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard expiryText.hasSuffix("Z"), let expiry = formatter.date(from: expiryText) else {
            throw RuleParseError.invalidExpiry
        }
        return ParsedOutOfOfficeConfiguration(
            emailAddress: emailAddress,
            subject: subject,
            message: message,
            expiryInstant: expiry
        )
    }

    private mutating func expect(_ literal: String) throws {
        guard source[cursor...].hasPrefix(literal) else { throw RuleParseError.invalidRule }
        cursor = source.index(cursor, offsetBy: literal.count)
    }

    private func hasPrefix(_ literal: String) -> Bool {
        source[cursor...].hasPrefix(literal)
    }

    private mutating func parseQuoted() throws -> String {
        guard cursor < source.endIndex, source[cursor] == "\"" else {
            throw RuleParseError.invalidString
        }
        cursor = source.index(after: cursor)
        var result = ""
        while cursor < source.endIndex {
            let character = source[cursor]
            cursor = source.index(after: cursor)
            if character == "\"" { return result }
            if character == "\\" {
                guard cursor < source.endIndex else { throw RuleParseError.invalidString }
                let escaped = source[cursor]
                cursor = source.index(after: cursor)
                guard escaped == "\\" || escaped == "\"" else {
                    throw RuleParseError.invalidString
                }
                result.append(escaped)
            } else {
                guard character != "\0" else { throw RuleParseError.invalidString }
                result.append(character)
            }
        }
        throw RuleParseError.invalidString
    }
}

private enum RuleParseError: Error {
    case invalidUTF8
    case invalidRequirements
    case invalidRule
    case invalidExpiry
    case invalidHandle
    case invalidString
}
