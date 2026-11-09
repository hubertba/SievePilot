import Foundation

enum ManagedScriptMetadataParseError: Error, Equatable {
    case invalidUTF8
    case invalidFormat
    case invalidAccountID
    case invalidVersionID
    case invalidPredecessorSHA256
}

enum ManagedScriptMetadataParser {
    static func parse(_ data: Data) throws -> ManagedScriptMetadata {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ManagedScriptMetadataParseError.invalidUTF8
        }
        var lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 5 else { throw ManagedScriptMetadataParseError.invalidFormat }
        guard lines[0] == "# BEGIN SIEVEPILOT METADATA v1",
              lines[4] == "# END SIEVEPILOT METADATA v1" else {
            throw ManagedScriptMetadataParseError.invalidFormat
        }

        let accountToken = try value(on: lines[1], prefix: "# account-id: ")
        let versionToken = try value(on: lines[2], prefix: "# version-id: ")
        let predecessorToken = try value(on: lines[3], prefix: "# predecessor-sha256: ")

        guard let accountUUID = UUID(uuidString: accountToken),
              accountUUID.uuidString.lowercased() == accountToken else {
            throw ManagedScriptMetadataParseError.invalidAccountID
        }
        guard let versionID = UUID(uuidString: versionToken),
              versionID.uuidString.lowercased() == versionToken else {
            throw ManagedScriptMetadataParseError.invalidVersionID
        }

        let predecessor = predecessorToken == "none" ? nil : predecessorToken
        do {
            return try ManagedScriptMetadata(
                accountID: AccountID(rawValue: accountUUID),
                versionID: versionID,
                predecessorSHA256: predecessor
            )
        } catch {
            throw ManagedScriptMetadataParseError.invalidPredecessorSHA256
        }
    }

    private static func value(on line: String, prefix: String) throws -> String {
        guard line.hasPrefix(prefix) else { throw ManagedScriptMetadataParseError.invalidFormat }
        let value = String(line.dropFirst(prefix.count))
        guard !value.isEmpty else { throw ManagedScriptMetadataParseError.invalidFormat }
        return value
    }
}
