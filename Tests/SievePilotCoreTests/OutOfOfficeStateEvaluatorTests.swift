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

        let state = OutOfOfficeStateEvaluator.evaluate(activeScript: script, now: expiry)

        guard case .malformed = state else {
            Issue.record("Expected malformed, got \(state)")
            return
        }
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
        ManagedScriptMetadata(
            accountID: accountID,
            versionID: UUID(uuidString: "D69D1F7D-7178-4A97-A801-EAE36BB7E05E")!,
            predecessorSHA256: "abc123"
        )
    }

    private func joined(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }
}
