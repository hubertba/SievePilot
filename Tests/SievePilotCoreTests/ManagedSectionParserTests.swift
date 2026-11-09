import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManagedSectionParserTests {
    @Test func testFindsOneValidSectionSetAtInsertionBoundary() throws {
        let rendered = try renderedSections()
        let prefix = Data("require \"fileinto\";\n".utf8)
        let suffix = Data("keep;\n".utf8)
        let script = joined(prefix, rendered.metadata, rendered.requirements, rendered.rule, suffix)
        let preamble = try SievePreambleScanner.scan(script)

        let sections = try ManagedSectionParser.parse(script, preamble: preamble)

        #expect(preamble.insertionOffset == prefix.count)
        #expect(sections.metadata == prefix.count..<(prefix.count + rendered.metadata.count))
        let requirementsStart = prefix.count + rendered.metadata.count
        #expect(sections.requirements == requirementsStart..<(requirementsStart + rendered.requirements.count))
        let ruleStart = requirementsStart + rendered.requirements.count
        #expect(sections.outOfOfficeRule == ruleStart..<(ruleStart + rendered.rule.count))
    }

    @Test func testMarkerTextInsideQuotedStringIsIgnored() throws {
        let script = Data("if header :contains \"subject\" \"# BEGIN SIEVEPILOT METADATA v1\" { keep; }\n".utf8)
        let preamble = try SievePreambleScanner.scan(script)

        let sections = try ManagedSectionParser.parse(script, preamble: preamble)

        #expect(sections == ManagedSections())
    }

    @Test func testMarkerTextInsideMultilineLiteralIsIgnored() throws {
        let script = Data("vacation text:\n# BEGIN SIEVEPILOT METADATA v1\n.\n;\n".utf8)
        let preamble = try SievePreambleScanner.scan(script)

        let sections = try ManagedSectionParser.parse(script, preamble: preamble)

        #expect(sections == ManagedSections())
    }

    @Test func testRejectsPartialMarkerPair() throws {
        let script = Data("# BEGIN SIEVEPILOT METADATA v1\n# account-id: abc\nkeep;\n".utf8)
        let preamble = try SievePreambleScanner.scan(script)

        #expect(throws: ManagedSectionError.partialMarker) {
            try ManagedSectionParser.parse(script, preamble: preamble)
        }
    }

    @Test func testRejectsDuplicateSection() throws {
        let metadata = try renderedSections().metadata
        let script = joined(metadata, metadata, Data("keep;\n".utf8))
        let preamble = try SievePreambleScanner.scan(script)

        #expect(throws: ManagedSectionError.duplicateSection) {
            try ManagedSectionParser.parse(script, preamble: preamble)
        }
    }

    @Test func testRejectsNestedSection() throws {
        let script = Data("""
        # BEGIN SIEVEPILOT METADATA v1
        # BEGIN SIEVEPILOT REQUIREMENTS v1
        # END SIEVEPILOT REQUIREMENTS v1
        # END SIEVEPILOT METADATA v1
        keep;
        """.utf8)
        let preamble = try SievePreambleScanner.scan(script)

        #expect(throws: ManagedSectionError.nestedSection) {
            try ManagedSectionParser.parse(script, preamble: preamble)
        }
    }

    @Test func testRejectsUnknownVersion() throws {
        let script = Data("# BEGIN SIEVEPILOT METADATA v2\n# END SIEVEPILOT METADATA v2\nkeep;\n".utf8)
        let preamble = try SievePreambleScanner.scan(script)

        #expect(throws: ManagedSectionError.unknownVersion) {
            try ManagedSectionParser.parse(script, preamble: preamble)
        }
    }

    @Test func testRejectsSectionAfterUserExecutableCommand() throws {
        let metadata = try renderedSections().metadata
        let script = joined(Data("keep;\n".utf8), metadata)
        let preamble = try SievePreambleScanner.scan(script)

        #expect(throws: ManagedSectionError.misplacedSection) {
            try ManagedSectionParser.parse(script, preamble: preamble)
        }
    }

    @Test func testAllowsMetadataOnlyDisabledVersion() throws {
        let metadata = try renderedSections().metadata
        let prefix = Data("require \"fileinto\";\n".utf8)
        let script = joined(prefix, metadata, Data("keep;\n".utf8))
        let preamble = try SievePreambleScanner.scan(script)

        let sections = try ManagedSectionParser.parse(script, preamble: preamble)

        #expect(sections.metadata == prefix.count..<(prefix.count + metadata.count))
        #expect(sections.requirements == nil)
        #expect(sections.outOfOfficeRule == nil)
    }

    private func renderedSections() throws -> RenderedManagedSections {
        let accountID = AccountID(
            rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!
        )
        let metadata = try ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: "D69D1F7D-7178-4A97-A801-EAE36BB7E05E")!,
            predecessorSHA256: String(repeating: "a", count: 64)
        )
        let configuration = try OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: "Away",
            message: "I am away.",
            expiry: ResolvedExpiry(
                instant: ISO8601DateFormatter().date(from: "2026-04-24T15:00:00Z")!,
                timeZoneIdentifier: "Europe/Warsaw",
                utcOffsetSeconds: 7_200
            )
        )
        return try ManagedSectionRenderer.renderOutOfOffice(
            configuration: configuration,
            metadata: metadata,
            lineEnding: .lf
        )
    }

    private func joined(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }
}
