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
            let existing: ManagedScriptMetadata
            do {
                existing = try ManagedScriptMetadataParser.parse(Data(script[metadataRange]))
            } catch {
                throw SieveScriptPatcherError.invalidManagedMetadata
            }
            guard existing.accountID == accountID else {
                throw SieveScriptPatcherError.accountIDMismatch
            }
        }

        var output = script
        if let metadataRange = sections.metadata {
            let operations = try replacements(
                for: mutation,
                metadata: metadata,
                lineEnding: preamble.preferredLineEnding,
                sections: sections,
                metadataRange: metadataRange
            )
            for operation in operations.sorted(by: {
                if $0.range.lowerBound == $1.range.lowerBound {
                    return $0.range.upperBound > $1.range.upperBound
                }
                return $0.range.lowerBound > $1.range.lowerBound
            }) {
                output.replaceSubrange(operation.range, with: operation.data)
            }
        } else {
            let replacement = try completeInsertion(
                for: mutation,
                metadata: metadata,
                lineEnding: preamble.preferredLineEnding
            )
            let separator = leadingSeparator(
                for: script,
                insertionOffset: preamble.insertionOffset,
                lineEnding: preamble.preferredLineEnding
            )
            output.insert(contentsOf: joined(separator, replacement), at: preamble.insertionOffset)
        }
        return output
    }

    private static func replacements(
        for mutation: SieveScriptMutation,
        metadata: ManagedScriptMetadata,
        lineEnding: LineEnding,
        sections: ManagedSections,
        metadataRange: Range<Int>
    ) throws -> [Replacement] {
        let renderedMetadata = ManagedSectionRenderer.renderMetadata(
            metadata,
            lineEnding: lineEnding
        )
        switch mutation {
        case let .enable(configuration):
            let rendered = try ManagedSectionRenderer.renderOutOfOffice(
                configuration: configuration,
                metadata: metadata,
                lineEnding: lineEnding
            )
            if let requirements = sections.requirements,
               let rule = sections.outOfOfficeRule {
                return [
                    Replacement(range: metadataRange, data: rendered.metadata),
                    Replacement(range: requirements, data: rendered.requirements),
                    Replacement(range: rule, data: rendered.rule)
                ]
            }
            return [
                Replacement(range: metadataRange.upperBound..<metadataRange.upperBound,
                            data: joined(rendered.requirements, rendered.rule)),
                Replacement(range: metadataRange, data: rendered.metadata)
            ]
        case .disable:
            var result = [Replacement(range: metadataRange, data: renderedMetadata)]
            if let requirements = sections.requirements {
                result.append(Replacement(range: requirements, data: Data()))
            }
            if let rule = sections.outOfOfficeRule {
                result.append(Replacement(range: rule, data: Data()))
            }
            return result
        }
    }

    private static func completeInsertion(
        for mutation: SieveScriptMutation,
        metadata: ManagedScriptMetadata,
        lineEnding: LineEnding
    ) throws -> Data {
        switch mutation {
        case let .enable(configuration):
            let rendered = try ManagedSectionRenderer.renderOutOfOffice(
                configuration: configuration,
                metadata: metadata,
                lineEnding: lineEnding
            )
            return joined(rendered.metadata, rendered.requirements, rendered.rule)
        case .disable:
            return ManagedSectionRenderer.renderMetadata(metadata, lineEnding: lineEnding)
        }
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

    private struct Replacement {
        let range: Range<Int>
        let data: Data
    }
}
