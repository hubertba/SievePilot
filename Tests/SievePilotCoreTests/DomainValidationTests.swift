import Foundation
import Testing
@testable import SievePilotCore

@Suite struct DomainValidationTests {
    private let expiry = ResolvedExpiry(
        instant: Date(timeIntervalSince1970: 1_800_000_000),
        timeZoneIdentifier: "Europe/Warsaw",
        utcOffsetSeconds: 7_200
    )

    @Test func testRejectsEmptyMessage() {
        #expect(throws: OutOfOfficeConfigurationError.emptyMessage) {
            try OutOfOfficeConfiguration(
                emailAddress: "user@example.com",
                subject: "Away",
                message: "  \n\t ",
                expiry: expiry
            )
        }
    }

    @Test func testAcceptsBlankSubjectAsNil() throws {
        let configuration = try OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: "  \t ",
            message: "Original message\n",
            expiry: expiry
        )

        #expect(configuration.subject == nil)
        #expect(configuration.message == "Original message\n")
    }

    @Test func testAccountIDSieveTokenContainsOnlyASCIIIdentifierCharacters() {
        let accountID = AccountID(
            rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!
        )

        #expect(accountID.sieveToken == "8cbcbcc8-2e3c-49be-9464-a238ad398005")
        #expect(accountID.sieveToken.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil)
    }

    @Test func testRejectsUnsafePredecessorSHA256() {
        let accountID = AccountID(rawValue: UUID())
        for unsafe in [
            "abc",
            String(repeating: "g", count: 64),
            String(repeating: "a", count: 63) + "\nkeep;",
            String(repeating: "a", count: 63) + "#"
        ] {
            #expect(throws: (any Error).self) {
                _ = try ManagedScriptMetadata(
                    accountID: accountID,
                    versionID: UUID(),
                    predecessorSHA256: unsafe
                )
            }
        }
    }

    @Test func testDecodingRejectsUnsafePredecessorSHA256() throws {
        let valid = try ManagedScriptMetadata(
            accountID: AccountID(rawValue: UUID()),
            versionID: UUID(),
            predecessorSHA256: String(repeating: "a", count: 64)
        )
        let encoded = try JSONEncoder().encode(valid)
        let unsafe = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(of: String(repeating: "a", count: 64), with: "unsafe")
                .utf8
        )

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ManagedScriptMetadata.self, from: unsafe)
        }
    }
}
