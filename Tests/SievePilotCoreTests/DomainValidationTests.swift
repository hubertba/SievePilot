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
}
