import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManagedSectionRendererTests {
    private let accountID = AccountID(
        rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!
    )

    @Test func testRendersCanonicalUTCStrictExclusiveCondition() throws {
        let sections = try render(subject: "Out of office")
        let rule = String(decoding: sections.rule, as: UTF8.self)

        #expect(rule.contains(
            "if currentdate :zone \"+0000\" :value \"lt\" \"iso8601\" \"2026-04-24T15:00:00Z\" {"
        ))
    }

    @Test func testOmitsSubjectTagWhenSubjectIsBlank() throws {
        let sections = try render(subject: " \t ")
        let rule = String(decoding: sections.rule, as: UTF8.self)

        #expect(!rule.contains(":subject"))
        #expect(rule.contains("\"I will reply when I return.\";"))
    }

    @Test func testRendersAddressesAndStableHandle() throws {
        let sections = try render(subject: "Out of office")
        let rule = String(decoding: sections.rule, as: UTF8.self)

        #expect(rule.contains(":addresses [\"user@example.com\"]"))
        #expect(rule.contains(
            ":handle \"sievepilot-out-of-office-8cbcbcc8-2e3c-49be-9464-a238ad398005\""
        ))
        #expect(rule.contains(":subject \"Out of office\""))
    }

    @Test func testRendersMultilineMessageAsExactQuotedString() throws {
        let metadata = try ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: "D69D1F7D-7178-4A97-A801-EAE36BB7E05E")!,
            predecessorSHA256: String(repeating: "a", count: 64)
        )
        let multiline = try OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: "Away",
            message: "Line one\n.Line two\n",
            expiry: ResolvedExpiry(
                instant: ISO8601DateFormatter().date(from: "2026-04-24T15:00:00Z")!,
                timeZoneIdentifier: "Europe/Warsaw",
                utcOffsetSeconds: 7_200
            )
        )

        let sections = try ManagedSectionRenderer.renderOutOfOffice(
            configuration: multiline,
            metadata: metadata,
            lineEnding: .lf
        )
        let rule = String(decoding: sections.rule, as: UTF8.self)

        #expect(rule.contains("        \"Line one\n.Line two\n\";"))
    }

    @Test func testUsesRequestedCRLFLineEndings() throws {
        let metadata = try ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: "D69D1F7D-7178-4A97-A801-EAE36BB7E05E")!,
            predecessorSHA256: String(repeating: "a", count: 64)
        )
        let sections = try ManagedSectionRenderer.renderOutOfOffice(
            configuration: configuration(subject: "Away"),
            metadata: metadata,
            lineEnding: .crlf
        )

        for section in [sections.metadata, sections.requirements, sections.rule] {
            let text = String(decoding: section, as: UTF8.self)
            #expect(text.contains("\r\n"))
            #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        }
    }

    private func render(subject: String?) throws -> RenderedManagedSections {
        let metadata = try ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: "D69D1F7D-7178-4A97-A801-EAE36BB7E05E")!,
            predecessorSHA256: String(repeating: "a", count: 64)
        )
        return try ManagedSectionRenderer.renderOutOfOffice(
            configuration: configuration(subject: subject),
            metadata: metadata,
            lineEnding: .lf
        )
    }

    private func configuration(subject: String?) -> OutOfOfficeConfiguration {
        try! OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: subject,
            message: "I will reply when I return.",
            expiry: ResolvedExpiry(
                instant: ISO8601DateFormatter().date(from: "2026-04-24T15:00:00Z")!,
                timeZoneIdentifier: "Europe/Warsaw",
                utcOffsetSeconds: 7_200
            )
        )
    }
}
