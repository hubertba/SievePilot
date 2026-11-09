import Foundation
import Testing
@testable import SievePilotCore

@Suite struct SieveScriptPatcherTests {
    private let accountID = AccountID(
        rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!
    )

    @Test func testEnableInsertsAfterExistingRequiresBeforeExecutableCode() throws {
        let original = Data("require \"fileinto\";\n# user rule\nkeep;\n".utf8)
        let insertionOffset = try SievePreambleScanner.scan(original).insertionOffset

        let output = try enable(original, message: "Away", metadata: metadata(version: 1))
        let sections = try parsed(output)

        #expect(sections.metadata?.lowerBound == insertionOffset)
        #expect(Data(output[..<sections.metadata!.lowerBound]) == Data(original[..<insertionOffset]))
        #expect(Data(output[sections.outOfOfficeRule!.upperBound...]) == Data(original[insertionOffset...]))
    }

    @Test func testUpdateReplacesOnlyOwnedRanges() throws {
        let original = Data("require \"fileinto\";\nkeep;\n".utf8)
        let insertionOffset = try SievePreambleScanner.scan(original).insertionOffset
        let first = try enable(original, message: "First message", metadata: metadata(version: 1))

        let updated = try enable(first, message: "Second message", metadata: metadata(version: 2))
        let sections = try parsed(updated)
        let text = String(decoding: updated, as: UTF8.self)

        #expect(Data(updated[..<sections.metadata!.lowerBound]) == Data(original[..<insertionOffset]))
        #expect(Data(updated[sections.outOfOfficeRule!.upperBound...]) == Data(original[insertionOffset...]))
        #expect(text.contains("Second message"))
        #expect(!text.contains("First message"))
    }

    @Test func testDisableLeavesMetadataAndRemovesRequirementsAndRule() throws {
        let original = Data("require \"fileinto\";\nkeep;\n".utf8)
        let enabled = try enable(original, message: "Away", metadata: metadata(version: 1))

        let disabled = try SieveScriptPatcher.apply(
            .disable,
            to: enabled,
            metadata: metadata(version: 2),
            accountID: accountID
        )
        let sections = try parsed(disabled)

        #expect(sections.metadata != nil)
        #expect(sections.requirements == nil)
        #expect(sections.outOfOfficeRule == nil)
        #expect(!String(decoding: disabled, as: UTF8.self).contains("vacation"))
    }

    @Test func testEnablePreservesBOMInvalidUTF8AndMixedLineEndingsOutsideOwnedRanges() throws {
        for name in ["invalid-utf8", "mixed-line-endings"] {
            let original = try fixture(named: name)
            let insertionOffset = try SievePreambleScanner.scan(original).insertionOffset

            let output = try enable(original, message: "Away", metadata: metadata(version: 1))
            let sections = try parsed(output)

            #expect(Data(output[..<sections.metadata!.lowerBound]) == Data(original[..<insertionOffset]))
            #expect(Data(output[sections.outOfOfficeRule!.upperBound...]) == Data(original[insertionOffset...]))
        }
    }

    @Test func testDisableRestoresAllOriginalUserBytesInOrder() throws {
        let original = Data("require \"fileinto\";\n# user bytes\nkeep;\n".utf8)
        let enabled = try enable(original, message: "Away", metadata: metadata(version: 1))
        let disabled = try SieveScriptPatcher.apply(
            .disable,
            to: enabled,
            metadata: metadata(version: 2),
            accountID: accountID
        )
        let sections = try parsed(disabled)
        var withoutMetadata = disabled
        withoutMetadata.removeSubrange(sections.metadata!)

        #expect(withoutMetadata == original)
    }

    @Test func testMalformedMarkersReturnErrorWithoutOutputMutation() {
        let original = Data("# BEGIN SIEVEPILOT METADATA v1\nkeep;\n".utf8)
        let snapshot = original

        #expect(throws: ManagedSectionError.partialMarker) {
            try enable(original, message: "Away", metadata: metadata(version: 1))
        }
        #expect(original == snapshot)
    }

    @Test func testUnknownVersionReturnsErrorWithoutOutputMutation() {
        let original = Data("# BEGIN SIEVEPILOT METADATA v2\n# END SIEVEPILOT METADATA v2\nkeep;\n".utf8)
        let snapshot = original

        #expect(throws: ManagedSectionError.unknownVersion) {
            try enable(original, message: "Away", metadata: metadata(version: 1))
        }
        #expect(original == snapshot)
    }

    @Test func testRepeatedEnableIsDeterministicApartFromMetadataVersionValues() throws {
        let original = Data("keep;\n".utf8)
        let first = try enable(original, message: "Away", metadata: metadata(version: 1))
        let second = try enable(original, message: "Away", metadata: metadata(version: 2))
        let firstMetadata = try parsed(first).metadata!
        let secondMetadata = try parsed(second).metadata!

        #expect(removing(firstMetadata, from: first) == removing(secondMetadata, from: second))
    }

    @Test func testUpdateAndDisablePreserveWhitespaceBetweenOwnedSections() throws {
        let original = Data("keep;\n".utf8)
        let enabled = try enable(original, message: "Away", metadata: metadata(version: 1))
        let sections = try parsed(enabled)
        let firstGap = Data("\r\n \t\r\n".utf8)
        let secondGap = Data("\n\t \n".utf8)
        var withGaps = enabled
        withGaps.insert(contentsOf: secondGap, at: sections.outOfOfficeRule!.lowerBound)
        withGaps.insert(contentsOf: firstGap, at: sections.requirements!.lowerBound)

        let updated = try enable(withGaps, message: "Updated", metadata: metadata(version: 2))
        let updatedSections = try parsed(updated)
        #expect(Data(updated[updatedSections.metadata!.upperBound..<updatedSections.requirements!.lowerBound]) == firstGap)
        #expect(Data(updated[updatedSections.requirements!.upperBound..<updatedSections.outOfOfficeRule!.lowerBound]) == secondGap)

        let disabled = try SieveScriptPatcher.apply(
            .disable,
            to: updated,
            metadata: metadata(version: 3),
            accountID: accountID
        )
        let disabledSections = try parsed(disabled)
        #expect(Data(disabled[disabledSections.metadata!.upperBound...]) == joined(firstGap, secondGap, original))
    }

    @Test func testInlineMarkerLookingCommentRemainsInlineAcrossLifecycle() throws {
        let original = Data("require \"fileinto\"; # BEGIN SIEVEPILOT METADATA v1\nkeep;\n".utf8)
        let enabled = try enable(original, message: "Away", metadata: metadata(version: 1))
        let updated = try enable(enabled, message: "Updated", metadata: metadata(version: 2))
        let disabled = try SieveScriptPatcher.apply(
            .disable,
            to: updated,
            metadata: metadata(version: 3),
            accountID: accountID
        )
        let sections = try parsed(disabled)

        #expect(removing(sections.metadata!, from: disabled) == original)
    }

    @Test func testRejectsMalformedMetadataBeforeMutation() throws {
        let malformed = Data("""
        # BEGIN SIEVEPILOT METADATA v1
        # account-id: \(accountID.sieveToken)
        # predecessor-sha256: \(String(repeating: "a", count: 64))
        # END SIEVEPILOT METADATA v1
        keep;
        """.utf8)

        #expect(throws: SieveScriptPatcherError.invalidManagedMetadata) {
            try enable(malformed, message: "Away", metadata: metadata(version: 2))
        }
    }

    @Test func testRejectsMetadataAccountMismatch() throws {
        let original = Data("keep;\n".utf8)
        let otherID = AccountID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        )

        #expect(throws: SieveScriptPatcherError.accountIDMismatch) {
            try SieveScriptPatcher.apply(
                .enable(configuration(message: "Away")),
                to: original,
                metadata: try ManagedScriptMetadata(
                    accountID: otherID,
                    versionID: UUID(),
                    predecessorSHA256: nil
                ),
                accountID: accountID
            )
        }
    }

    private func enable(
        _ script: Data,
        message: String,
        metadata: ManagedScriptMetadata
    ) throws -> Data {
        try SieveScriptPatcher.apply(
            .enable(configuration(message: message)),
            to: script,
            metadata: metadata,
            accountID: accountID
        )
    }

    private func parsed(_ script: Data) throws -> ManagedSections {
        let preamble = try SievePreambleScanner.scan(script)
        return try ManagedSectionParser.parse(script, preamble: preamble)
    }

    private func metadata(version: Int) -> ManagedScriptMetadata {
        try! ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", version))!,
            predecessorSHA256: String(repeating: "a", count: 64)
        )
    }

    private func rendered(
        message: String,
        metadata: ManagedScriptMetadata
    ) throws -> RenderedManagedSections {
        try ManagedSectionRenderer.renderOutOfOffice(
            configuration: configuration(message: message),
            metadata: metadata,
            lineEnding: .lf
        )
    }

    private func configuration(message: String) -> OutOfOfficeConfiguration {
        try! OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: "Away",
            message: message,
            expiry: ResolvedExpiry(
                instant: ISO8601DateFormatter().date(from: "2026-04-24T15:00:00Z")!,
                timeZoneIdentifier: "Europe/Warsaw",
                utcOffsetSeconds: 7_200
            )
        )
    }

    private func fixture(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "sieve"))
        return try Data(contentsOf: url)
    }

    private func removing(_ range: Range<Int>, from data: Data) -> Data {
        var copy = data
        copy.removeSubrange(range)
        return copy
    }

    private func joined(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }
}
