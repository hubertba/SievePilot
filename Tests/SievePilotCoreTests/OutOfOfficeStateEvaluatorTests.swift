import Foundation
import Testing
@testable import SievePilotCore

@Suite struct OutOfOfficeStateEvaluatorTests {
    private let accountID = AccountID(
        rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!
    )
    private let expiry = ISO8601DateFormatter().date(from: "2026-04-24T15:00:00Z")!

    @Test func testNoActiveScriptIsVerifiedOff() {
        #expect(OutOfOfficeStateEvaluator.evaluate(activeScript: nil, now: expiry) == .off)
    }

    @Test func testMetadataOnlyScriptIsVerifiedOff() throws {
        let script = try SieveScriptPatcher.apply(
            .disable,
            to: Data("keep;\n".utf8),
            metadata: metadata(),
            accountID: accountID
        )

        #expect(OutOfOfficeStateEvaluator.evaluate(activeScript: script, now: expiry) == .off)
    }

    @Test func testFutureRuleIsVerifiedOn() throws {
        let script = try enabledScript()
        let state = OutOfOfficeStateEvaluator.evaluate(
            activeScript: script,
            now: expiry.addingTimeInterval(-1)
        )

        guard case let .on(configuration) = state else {
            Issue.record("Expected verified on, got \(state)")
            return
        }
        #expect(configuration.emailAddress == "user@example.com")
        #expect(configuration.subject == "Away")
        #expect(configuration.message == "I am away.")
        #expect(configuration.expiryInstant == expiry)
    }

    @Test func testLocallyExpiredRuleUsesServerClockWarningState() throws {
        let script = try enabledScript()
        let state = OutOfOfficeStateEvaluator.evaluate(activeScript: script, now: expiry)

        guard case let .expiryPassedServerClockApplies(configuration) = state else {
            Issue.record("Expected server-clock warning, got \(state)")
            return
        }
        #expect(configuration.expiryInstant == expiry)
    }

    @Test func testMalformedOwnedRuleIsMalformedNotOff() throws {
        let rendered = try renderedSections()
        let malformedRule = Data("""
        # BEGIN SIEVEPILOT RULE v1: out-of-office
        redirect "other@example.com";
        # END SIEVEPILOT RULE v1: out-of-office
        """.utf8)
        let script = joined(rendered.metadata, rendered.requirements, malformedRule, Data("keep;\n".utf8))

        expectMalformed(script)
    }

    @Test func testRejectsExtraQuotedTokensInvalidUTF8AndAlteredHandle() throws {
        let rendered = try renderedSections()
        let originalRule = rendered.rule
        let extraToken = replacing(
            Data("        \"I am away.\";".utf8),
            with: Data("        \"a\" \"b\";".utf8),
            in: originalRule
        )
        let alteredHandle = replacing(
            Data(":handle \"sievepilot-out-of-office-\(accountID.sieveToken)\"".utf8),
            with: Data(":handle \"sievepilot-out-of-office-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\"".utf8),
            in: originalRule
        )
        var invalidUTF8 = originalRule
        let message = invalidUTF8.range(of: Data("I am away.".utf8))!
        invalidUTF8.replaceSubrange(message, with: Data([0xff]))

        for rule in [extraToken, alteredHandle, invalidUTF8] {
            expectMalformed(joined(rendered.metadata, rendered.requirements, rule, Data("keep;\n".utf8)))
        }
    }

    @Test func testRejectsMalformedMetadataAndMetadataHandleMismatch() throws {
        let rendered = try renderedSections()
        let validAccount = accountID.sieveToken
        let otherAccount = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let malformedMetadata = [
            Data("""
            # BEGIN SIEVEPILOT METADATA v1
            # account-id: \(validAccount)
            # predecessor-sha256: \(String(repeating: "a", count: 64))
            # END SIEVEPILOT METADATA v1
            """.utf8),
            Data("""
            # BEGIN SIEVEPILOT METADATA v1
            # account-id: \(validAccount)
            # account-id: \(validAccount)
            # version-id: d69d1f7d-7178-4a97-a801-eae36bb7e05e
            # predecessor-sha256: \(String(repeating: "a", count: 64))
            # END SIEVEPILOT METADATA v1
            """.utf8),
            Data("""
            # BEGIN SIEVEPILOT METADATA v1
            # account-id: \(validAccount)
            keep;
            # version-id: d69d1f7d-7178-4a97-a801-eae36bb7e05e
            # predecessor-sha256: \(String(repeating: "a", count: 64))
            # END SIEVEPILOT METADATA v1
            """.utf8),
            replacing(Data(validAccount.utf8), with: Data(otherAccount.utf8), in: rendered.metadata)
        ]

        for metadata in malformedMetadata {
            expectMalformed(joined(metadata, rendered.requirements, rendered.rule, Data("keep;\n".utf8)))
        }
    }

    @Test func testMultilineMessageRoundTripsThroughVerifiedState() throws {
        let multiline = try OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: "Away",
            message: "Line one\n.Line two\n",
            expiry: ResolvedExpiry(
                instant: expiry,
                timeZoneIdentifier: "Europe/Warsaw",
                utcOffsetSeconds: 7_200
            )
        )
        let script = try SieveScriptPatcher.apply(
            .enable(multiline),
            to: Data("keep;\n".utf8),
            metadata: metadata(),
            accountID: accountID
        )
        let state = OutOfOfficeStateEvaluator.evaluate(
            activeScript: script,
            now: expiry.addingTimeInterval(-1)
        )

        guard case let .on(parsed) = state else {
            Issue.record("Expected verified on, got \(state)")
            return
        }
        #expect(parsed.message == "Line one\n.Line two\n")
    }

    private func enabledScript() throws -> Data {
        try SieveScriptPatcher.apply(
            .enable(configuration()),
            to: Data("keep;\n".utf8),
            metadata: metadata(),
            accountID: accountID
        )
    }

    private func renderedSections() throws -> RenderedManagedSections {
        try ManagedSectionRenderer.renderOutOfOffice(
            configuration: configuration(),
            metadata: metadata(),
            lineEnding: .lf
        )
    }

    private func configuration() -> OutOfOfficeConfiguration {
        try! OutOfOfficeConfiguration(
            emailAddress: "user@example.com",
            subject: "Away",
            message: "I am away.",
            expiry: ResolvedExpiry(
                instant: expiry,
                timeZoneIdentifier: "Europe/Warsaw",
                utcOffsetSeconds: 7_200
            )
        )
    }

    private func metadata() -> ManagedScriptMetadata {
        try! ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: "D69D1F7D-7178-4A97-A801-EAE36BB7E05E")!,
            predecessorSHA256: String(repeating: "a", count: 64)
        )
    }

    private func expectMalformed(_ script: Data) {
        let state = OutOfOfficeStateEvaluator.evaluate(activeScript: script, now: expiry)
        guard case .malformed = state else {
            Issue.record("Expected malformed, got \(state)")
            return
        }
    }

    private func replacing(_ needle: Data, with replacement: Data, in data: Data) -> Data {
        var copy = data
        let range = copy.range(of: needle)!
        copy.replaceSubrange(range, with: replacement)
        return copy
    }

    private func joined(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }
}
