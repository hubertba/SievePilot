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
            guard sections.metadata != nil else { return .off }
            guard
                let requirementsRange = sections.requirements,
                let ruleRange = sections.outOfOfficeRule
            else {
                return .off
            }

            try validateRequirements(Data(activeScript[requirementsRange]))
            let configuration = try parseRule(Data(activeScript[ruleRange]))
            if now < configuration.expiryInstant {
                return .on(configuration: configuration)
            }
            return .expiryPassedServerClockApplies(configuration: configuration)
        } catch {
            return .malformed(reason: String(describing: error))
        }
    }

    private static func validateRequirements(_ data: Data) throws {
        let actual = normalize(data).trimmingCharacters(in: .newlines)
        let expected = """
        # BEGIN SIEVEPILOT REQUIREMENTS v1
        require ["vacation", "date", "relational"];
        # END SIEVEPILOT REQUIREMENTS v1
        """
        guard actual == expected else { throw RuleParseError.invalidRequirements }
    }

    private static func parseRule(_ data: Data) throws -> ParsedOutOfOfficeConfiguration {
        var lines = normalize(data).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 8 || lines.count == 9 else { throw RuleParseError.invalidRule }
        guard lines[0] == "# BEGIN SIEVEPILOT RULE v1: out-of-office" else {
            throw RuleParseError.invalidRule
        }
        guard lines[2] == "    vacation" else { throw RuleParseError.invalidRule }
        guard lines[lines.count - 2] == "}" else { throw RuleParseError.invalidRule }
        guard lines[lines.count - 1] == "# END SIEVEPILOT RULE v1: out-of-office" else {
            throw RuleParseError.invalidRule
        }

        let expiryText = try enclosed(
            lines[1],
            prefix: "if currentdate :zone \"+0000\" :value \"lt\" \"iso8601\" \"",
            suffix: "\" {"
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let expiry = formatter.date(from: expiryText), expiryText.hasSuffix("Z") else {
            throw RuleParseError.invalidExpiry
        }

        let addressSource = try enclosed(lines[3], prefix: "        :addresses [", suffix: "]")
        let emailAddress = try decodeQuoted(addressSource)
        let handle = try decodeQuoted(
            enclosed(lines[4], prefix: "        :handle ", suffix: "")
        )
        guard handle.hasPrefix("sievepilot-out-of-office-") else {
            throw RuleParseError.invalidHandle
        }

        let subject: String?
        let messageLine: String
        if lines.count == 9 {
            subject = try decodeQuoted(
                enclosed(lines[5], prefix: "        :subject ", suffix: "")
            )
            messageLine = lines[6]
        } else {
            subject = nil
            messageLine = lines[5]
        }
        let message = try decodeQuoted(
            enclosed(messageLine, prefix: "        ", suffix: ";")
        )

        return ParsedOutOfOfficeConfiguration(
            emailAddress: emailAddress,
            subject: subject,
            message: message,
            expiryInstant: expiry
        )
    }

    private static func normalize(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func enclosed(_ value: String, prefix: String, suffix: String) throws -> String {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else {
            throw RuleParseError.invalidRule
        }
        return String(value.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func decodeQuoted(_ value: String) throws -> String {
        guard value.first == "\"", value.last == "\"", value.count >= 2 else {
            throw RuleParseError.invalidString
        }
        let characters = Array(value.dropFirst().dropLast())
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\" {
                index += 1
                guard index < characters.count,
                      characters[index] == "\\" || characters[index] == "\"" else {
                    throw RuleParseError.invalidString
                }
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    private enum RuleParseError: Error {
        case invalidRequirements
        case invalidRule
        case invalidExpiry
        case invalidHandle
        case invalidString
    }
}
