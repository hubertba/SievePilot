import Foundation
import XCTest
@testable import SievePilotCore

// Opt-in interoperability tests against a real ManageSieve server.
//
// Every test skips unless the process environment explicitly enables it. Nothing here reads a `.env`
// file or any other credential source: only `ProcessInfo.processInfo.environment` is consulted, and
// the skip decision happens before any network object is constructed. See docs/live-interoperability.md.
//
// Assertion messages never include the password, authentication payloads, script bodies, or raw
// server text; they name variables, script-name roles, and error types only.

private enum LiveEnvironment {
    static let enable = "SIEVEPILOT_LIVE_INTEROP"
    static let email = "SIEVEPILOT_LIVE_EMAIL"
    static let username = "SIEVEPILOT_LIVE_USERNAME"
    static let password = "SIEVEPILOT_LIVE_PASSWORD"
    static let sourceDomain = "SIEVEPILOT_LIVE_SOURCE_DOMAIN"
    static let host = "SIEVEPILOT_LIVE_HOST"
    static let port = "SIEVEPILOT_LIVE_PORT"
    static let destructive = "SIEVEPILOT_LIVE_DESTRUCTIVE"
    static let dedicatedAccountAcknowledgement = "SIEVEPILOT_LIVE_DEDICATED_ACCOUNT_ACK"
    static let acknowledgementValue = "dedicated-account-backed-up"
}

private enum LiveConfigurationError: Error, CustomStringConvertible {
    case invalid(variables: [String], reason: String)

    var description: String {
        switch self {
        case .invalid(let variables, let reason):
            return "Invalid live interoperability configuration (\(variables.joined(separator: ", "))): \(reason)"
        }
    }
}

private struct LiveConfiguration: Sendable {
    let account: AccountConfiguration
    let password: Data

    /// Throws `XCTSkip` unless the opt-in variables are present. Throws `LiveConfigurationError`
    /// (naming variables only) when opted in with an unusable configuration.
    static func load(destructive: Bool) throws -> LiveConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment[LiveEnvironment.enable] == "1" else {
            throw XCTSkip("Set \(LiveEnvironment.enable)=1 and the variables in docs/live-interoperability.md to run")
        }
        if destructive {
            guard environment[LiveEnvironment.destructive] == "1" else {
                throw XCTSkip("Set \(LiveEnvironment.destructive)=1 to run the destructive interoperability test")
            }
            guard environment[LiveEnvironment.dedicatedAccountAcknowledgement] == LiveEnvironment.acknowledgementValue else {
                throw XCTSkip("Set \(LiveEnvironment.dedicatedAccountAcknowledgement) as documented to run the destructive interoperability test")
            }
        }

        func value(_ name: String) -> String? {
            guard let raw = environment[name], !raw.isEmpty else { return nil }
            return raw
        }
        let missing = [LiveEnvironment.email, LiveEnvironment.username, LiveEnvironment.password].filter { value($0) == nil }
        guard missing.isEmpty, let email = value(LiveEnvironment.email), let username = value(LiveEnvironment.username),
              let password = value(LiveEnvironment.password) else {
            throw LiveConfigurationError.invalid(variables: missing, reason: "required variable is unset or empty")
        }

        let endpoint: AccountEndpointPolicy
        let domain = value(LiveEnvironment.sourceDomain)
        let host = value(LiveEnvironment.host)
        let port = value(LiveEnvironment.port)
        switch (domain, host, port) {
        case (let domain?, nil, nil):
            endpoint = .automatic(sourceDomain: domain)
        case (nil, let host?, let port?):
            guard let number = Int(port) else {
                throw LiveConfigurationError.invalid(variables: [LiveEnvironment.port], reason: "not an integer")
            }
            endpoint = .manual(host: host, port: number)
        default:
            throw LiveConfigurationError.invalid(
                variables: [LiveEnvironment.sourceDomain, LiveEnvironment.host, LiveEnvironment.port],
                reason: "set either \(LiveEnvironment.sourceDomain) alone, or both \(LiveEnvironment.host) and \(LiveEnvironment.port)")
        }

        let account: AccountConfiguration
        do {
            account = try AccountConfiguration(accountID: AccountID(rawValue: UUID()), emailAddress: email,
                                               username: username, endpointPolicy: endpoint, tlsPolicy: .startTLS)
        } catch {
            throw LiveConfigurationError.invalid(
                variables: [LiveEnvironment.email, LiveEnvironment.username,
                            LiveEnvironment.sourceDomain, LiveEnvironment.host, LiveEnvironment.port],
                reason: "account settings rejected (\(type(of: error)))")
        }
        return LiveConfiguration(account: account, password: Data(password.utf8))
    }
}

private struct InMemoryCredentialStore: CredentialStoring {
    let password: Data
    func read(accountID: AccountID) async throws -> Data? { password }
    func write(_ password: Data, accountID: AccountID) async throws {}
    func delete(accountID: AccountID) async throws {}
}

private struct ServerState: Sendable {
    let entries: [ManageSieveScriptEntry]
    let activeName: String?
    let activeScript: Data?

    var names: Set<String> { Set(entries.map(\.name)) }
}

private struct InteropFailure: Error, CustomStringConvertible {
    let description: String
}

private func safeDescription(_ error: Error) -> String {
    switch error {
    case is ManageSieveClientError, is SieveAccountServiceError, is ManageSieveSessionFactoryError:
        return String(describing: error)
    default:
        return String(describing: type(of: error))
    }
}

final class LiveManageSieveInteropTests: XCTestCase {
    func testConnectsSecurelyAuthenticatesAndReadsCapabilities() async throws {
        let configuration = try LiveConfiguration.load(destructive: false)
        let factory = ManageSieveSessionFactory(credentialStore: InMemoryCredentialStore(password: configuration.password))

        // Success implies: TCP connect, STARTTLS, certificate trust and service-identity validation,
        // authentication only afterwards, and an authoritative post-TLS capability list.
        let report: (authoritative: Bool, hasSASL: Bool, hasSieve: Bool, missingExtensions: [String]) =
            try await factory.withAuthenticatedSession(account: configuration.account, password: configuration.password) { session in
                let capabilities = await session.capabilities
                let required = ["vacation", "date", "relational"]
                return (capabilities.isAuthoritative, capabilities.containsCapability("SASL"),
                        capabilities.containsCapability("SIEVE"),
                        required.filter { !capabilities.supportsSieveExtension($0) })
            }
        XCTAssertTrue(report.authoritative, "Capabilities after authentication must be the post-TLS list")
        XCTAssertTrue(report.hasSASL, "Server did not advertise SASL")
        XCTAssertTrue(report.hasSieve, "Server did not advertise SIEVE")
        XCTAssertEqual(report.missingExtensions, [], "Server lacks required Sieve extensions")

        // A second, independent session proves the first logout/close left the account usable.
        let secondAuthoritative = try await factory.withAuthenticatedSession(
            account: configuration.account, password: configuration.password) { session in
            await session.capabilities.isAuthoritative
        }
        XCTAssertTrue(secondAuthoritative, "Second session did not report authoritative capabilities")
    }

    func testDestructiveScriptRoundTripActivationRollbackAndCleanup() async throws {
        let configuration = try LiveConfiguration.load(destructive: true)
        let account = configuration.account
        let factory = ManageSieveSessionFactory(credentialStore: InMemoryCredentialStore(password: configuration.password))
        let token = account.accountID.sieveToken
        let ownedPrefixes = ["sievepilot-\(token)-", "sievepilot-interop-\(token)-"]

        let manifestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sievepilot-live-interop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: manifestDirectory) }
        let manifestStore = OwnedScriptManifestStore(baseDirectory: manifestDirectory)
        let service = SieveAccountService(sessionProvider: factory, manifestStore: manifestStore)

        // Baseline is captured before any mutation; it is never written back, only compared against.
        let initial = try await Self.readState(factory: factory, configuration: configuration)

        var failure: Error?
        do {
            try await exerciseRoundTripAndActivation(
                factory: factory, service: service, manifestStore: manifestStore,
                configuration: configuration, ownedPrefixes: ownedPrefixes)
        } catch {
            failure = error
        }

        // Rollback and cleanup run even when the exercise failed or was cancelled.
        var cleanupFailure: Error?
        do {
            let manifestNames = ((try? await manifestStore.load(accountID: account.accountID)) ?? []).map(\.name)
            try await Self.restore(initial: initial, ownedPrefixes: ownedPrefixes, extraOwnedNames: manifestNames,
                                   factory: factory, configuration: configuration)
        } catch {
            cleanupFailure = error
        }

        if let failure { throw failure }
        if let cleanupFailure {
            XCTFail("Rollback or cleanup failed (\(safeDescription(cleanupFailure))); inspect the dedicated account for names starting with sievepilot-")
        }
    }

    // MARK: - Exercise

    private func exerciseRoundTripAndActivation(
        factory: ManageSieveSessionFactory, service: SieveAccountService, manifestStore: OwnedScriptManifestStore,
        configuration: LiveConfiguration, ownedPrefixes: [String]
    ) async throws {
        let account = configuration.account

        // 1. Exact byte round trip of an inactive script: multi-byte UTF-8, mixed line endings,
        //    CRLF and bare LF, and no trailing newline.
        let roundTripName = "\(ownedPrefixes[1])\(UUID().uuidString.lowercased())"
        let script = Data("# SievePilot interoperability \u{00e9}\u{4e2d}\u{1F4E8}\r\nkeep;\n# no trailing newline".utf8)
        let outcome: (matches: Bool, inactive: Bool, listed: Bool, removed: Bool) =
            try await factory.withAuthenticatedSession(account: account, password: configuration.password) { session in
                _ = try await session.putScript(name: roundTripName, script: script, timeout: nil)
                let readBack = try await session.getScript(name: roundTripName, timeout: nil)
                let entries = try await session.listScripts(timeout: nil)
                let entry = entries.first { $0.name == roundTripName }
                try await session.deleteScript(name: roundTripName, timeout: nil)
                let afterDelete = try await session.listScripts(timeout: nil)
                return (readBack == script, entry?.isActive == false, entry != nil,
                        !afterDelete.contains { $0.name == roundTripName })
            }
        XCTAssertTrue(outcome.listed, "Uploaded round-trip script was not listed")
        XCTAssertTrue(outcome.inactive, "Uploading a script must not activate it")
        XCTAssertTrue(outcome.matches, "Round-tripped script bytes differ from the uploaded bytes")
        XCTAssertTrue(outcome.removed, "Round-trip script was not deleted")

        // 2. Candidate activation and byte-identical read-back through the production service.
        let expiry = ResolvedExpiry(instant: Date().addingTimeInterval(3_600), timeZoneIdentifier: "UTC", utcOffsetSeconds: 0)
        let outOfOffice = try OutOfOfficeConfiguration(
            emailAddress: account.emailAddress, subject: "SievePilot interoperability test",
            message: "Automated interoperability test; please ignore.", expiry: expiry)
        let enabled = try await service.applyOutOfOffice(account: account, configuration: outOfOffice)
        guard case .verified(let enabledSnapshot) = enabled else {
            throw InteropFailure(description: "Enabling out of office was not verified (\(Self.label(enabled)))")
        }
        XCTAssertTrue(enabledSnapshot.activeScriptName?.hasPrefix(ownedPrefixes[0]) ?? false,
                      "Activated script does not use a SievePilot-owned name")
        if case .on = enabledSnapshot.outOfOfficeState {} else { XCTFail("Verified state after enabling is not On") }

        // 3. Candidate disable: a second owned version, verified Off.
        let disabled = try await service.applyOutOfOffice(account: account, configuration: nil)
        guard case .verified(let disabledSnapshot) = disabled else {
            throw InteropFailure(description: "Disabling out of office was not verified (\(Self.label(disabled)))")
        }
        if case .off = disabledSnapshot.outOfOfficeState {} else { XCTFail("Verified state after disabling is not Off") }
        XCTAssertNotEqual(enabledSnapshot.activeScriptName, disabledSnapshot.activeScriptName,
                          "Each activation must use a new script name")

        let records = try await manifestStore.load(accountID: account.accountID)
        XCTAssertEqual(records.filter { $0.phase == .verifiedActive }.count, 2, "Expected two verified owned versions")
    }

    private static func label(_ outcome: AccountMutationOutcome) -> String {
        switch outcome {
        case .verified: return "verified"
        case .conflict: return "conflict"
        case .unknown: return "unknown"
        }
    }

    // MARK: - Server state helpers

    private static func readState(factory: ManageSieveSessionFactory, configuration: LiveConfiguration) async throws -> ServerState {
        try await factory.withAuthenticatedSession(account: configuration.account, password: configuration.password) { session in
            let entries = try await session.listScripts(timeout: nil)
            let activeName = entries.first(where: \.isActive)?.name
            let script: Data?
            if let activeName { script = try await session.getScript(name: activeName, timeout: nil) } else { script = nil }
            return ServerState(entries: entries, activeName: activeName, activeScript: script)
        }
    }

    /// Restores the previously active script (or no active script), deletes only names created by this
    /// test run, then verifies the server matches the initial state. User-named scripts are never deleted.
    private static func restore(initial: ServerState, ownedPrefixes: [String], extraOwnedNames: [String],
                                factory: ManageSieveSessionFactory, configuration: LiveConfiguration) async throws {
        try await factory.withAuthenticatedSession(account: configuration.account, password: configuration.password) { session in
            let before = initial.names
            let current = try await session.listScripts(timeout: nil)
            let currentActive = current.first(where: \.isActive)?.name
            if currentActive != initial.activeName {
                try await session.setActive(name: initial.activeName ?? "", timeout: nil)
            }
            let extra = Set(extraOwnedNames)
            for entry in current where !before.contains(entry.name)
                && (ownedPrefixes.contains { entry.name.hasPrefix($0) } || extra.contains(entry.name)) {
                try await session.deleteScript(name: entry.name, timeout: nil)
            }

            let final = try await session.listScripts(timeout: nil)
            guard Set(final.map(\.name)) == before else {
                throw InteropFailure(description: "Script names differ from the initial state after cleanup")
            }
            guard final.first(where: \.isActive)?.name == initial.activeName else {
                throw InteropFailure(description: "Active script differs from the initial state after rollback")
            }
            if let name = initial.activeName {
                let bytes = try await session.getScript(name: name, timeout: nil)
                guard bytes == initial.activeScript else {
                    throw InteropFailure(description: "Original active script bytes changed")
                }
            }
        }
    }
}
