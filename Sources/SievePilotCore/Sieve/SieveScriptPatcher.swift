import Foundation

public enum SieveScriptMutation: Sendable {
    case enable(OutOfOfficeConfiguration)
    case disable
}

public enum SieveScriptPatcherError: Error, Equatable, Sendable {
    case accountIDMismatch
    case invalidManagedMetadata
}

public enum SieveScriptPatcher {
    public static func apply(
        _ mutation: SieveScriptMutation,
        to script: Data,
        metadata: ManagedScriptMetadata,
        accountID: AccountID
    ) throws -> Data {
        guard metadata.accountID == accountID else {
            throw SieveScriptPatcherError.accountIDMismatch
        }

        let preamble = try SievePreambleScanner.scan(script)
        let sections = try ManagedSectionParser.parse(script, preamble: preamble)
        if let metadataRange = sections.metadata {
            let existingAccountID = try accountIDToken(in: script[metadataRange])
            guard existingAccountID == accountID.sieveToken else {
                throw SieveScriptPatcherError.accountIDMismatch
            }
        }

        let replacement: Data
        switch mutation {
        case let .enable(configuration):
            let rendered = try ManagedSectionRenderer.renderOutOfOffice(
                configuration: configuration,
                metadata: metadata,
                lineEnding: preamble.preferredLineEnding
            )
            replacement = joined(rendered.metadata, rendered.requirements, rendered.rule)
        case .disable:
            replacement = ManagedSectionRenderer.renderMetadata(
                metadata,
                lineEnding: preamble.preferredLineEnding
            )
        }

        var output = script
        if let metadataRange = sections.metadata {
            let end = sections.outOfOfficeRule?.upperBound
                ?? sections.requirements?.upperBound
                ?? metadataRange.upperBound
            output.replaceSubrange(metadataRange.lowerBound..<end, with: replacement)
        } else {
            let separator = leadingSeparator(
                for: script,
                insertionOffset: preamble.insertionOffset,
                lineEnding: preamble.preferredLineEnding
            )
            output.insert(contentsOf: joined(separator, replacement), at: preamble.insertionOffset)
        }
        return output
    }

    private static func accountIDToken(in metadata: Data.SubSequence) throws -> String {
        let text = String(decoding: metadata, as: UTF8.self)
        guard let line = text.split(whereSeparator: \Character.isNewline).first(where: {
            $0.hasPrefix("# account-id: ")
        }) else {
            throw SieveScriptPatcherError.invalidManagedMetadata
        }
        return String(line.dropFirst("# account-id: ".count))
    }

    private static func leadingSeparator(
        for script: Data,
        insertionOffset: Int,
        lineEnding: LineEnding
    ) -> Data {
        guard insertionOffset > 0 else { return Data() }
        let previous = script[script.index(script.startIndex, offsetBy: insertionOffset - 1)]
        guard previous != 0x0a, previous != 0x0d else { return Data() }
        return Data(lineEnding.rawValue.utf8)
    }

    private static func joined(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }
}
