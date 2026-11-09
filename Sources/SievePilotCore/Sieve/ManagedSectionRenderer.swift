import Foundation

public enum LineEnding: String, Codable, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
}

public struct RenderedManagedSections: Equatable, Sendable {
    public let metadata: Data
    public let requirements: Data
    public let rule: Data

    public init(metadata: Data, requirements: Data, rule: Data) {
        self.metadata = metadata
        self.requirements = requirements
        self.rule = rule
    }
}

public enum ManagedSectionRenderer {
    public static func renderMetadata(
        _ metadata: ManagedScriptMetadata,
        lineEnding: LineEnding
    ) -> Data {
        let newline = lineEnding.rawValue
        let predecessor = metadata.predecessorSHA256 ?? "none"
        let source = [
            "# BEGIN SIEVEPILOT METADATA v1",
            "# account-id: \(metadata.accountID.sieveToken)",
            "# version-id: \(metadata.versionID.uuidString.lowercased())",
            "# predecessor-sha256: \(predecessor)",
            "# END SIEVEPILOT METADATA v1",
            ""
        ].joined(separator: newline)
        return Data(source.utf8)
    }

    public static func renderOutOfOffice(
        configuration: OutOfOfficeConfiguration,
        metadata: ManagedScriptMetadata,
        lineEnding: LineEnding
    ) throws -> RenderedManagedSections {
        let newline = lineEnding.rawValue
        let address = try string(encoding: configuration.emailAddress)
        let handle = try string(
            encoding: "sievepilot-out-of-office-\(metadata.accountID.sieveToken)"
        )
        let message = String(
            decoding: try SieveStringEncoder.encodeMessageQuoted(configuration.message),
            as: UTF8.self
        )
        let expiry = utcTimestamp(configuration.expiry.instant)

        let requirements = [
            "# BEGIN SIEVEPILOT REQUIREMENTS v1",
            "require [\"vacation\", \"date\", \"relational\"];",
            "# END SIEVEPILOT REQUIREMENTS v1",
            ""
        ].joined(separator: newline)

        var ruleLines = [
            "# BEGIN SIEVEPILOT RULE v1: out-of-office",
            "if currentdate :zone \"+0000\" :value \"lt\" \"iso8601\" \"\(expiry)\" {",
            "    vacation",
            "        :addresses [\(address)]",
            "        :handle \(handle)"
        ]
        if let subject = configuration.subject {
            ruleLines.append("        :subject \(try string(encoding: subject))")
        }
        ruleLines.append("        \(message);")
        ruleLines.append("}")
        ruleLines.append("# END SIEVEPILOT RULE v1: out-of-office")
        ruleLines.append("")

        return RenderedManagedSections(
            metadata: renderMetadata(metadata, lineEnding: lineEnding),
            requirements: Data(requirements.utf8),
            rule: Data(ruleLines.joined(separator: newline).utf8)
        )
    }

    private static func string(encoding value: String) throws -> String {
        String(decoding: try SieveStringEncoder.encodeQuoted(value), as: UTF8.self)
    }

    private static func utcTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
