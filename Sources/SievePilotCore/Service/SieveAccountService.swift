import CryptoKit
import Foundation
import Security

public struct VerifiedAccountSnapshot: Equatable, Sendable {
    public let activeScriptName: String?
    public let activeScript: Data?
    public let scripts: [ManageSieveScriptEntry]
    public let outOfOfficeState: VerifiedOutOfOfficeState
    public let verifiedAt: Date
    public let capabilities: ManageSieveCapabilities

    public init(activeScriptName: String?, activeScript: Data?,
                scripts: [ManageSieveScriptEntry] = [],
                outOfOfficeState: VerifiedOutOfOfficeState,
                verifiedAt: Date, capabilities: ManageSieveCapabilities) {
        self.activeScriptName = activeScriptName
        self.activeScript = activeScript
        self.scripts = scripts
        self.outOfOfficeState = outOfOfficeState
        self.verifiedAt = verifiedAt
        self.capabilities = capabilities
    }
}

public enum AccountMutationOutcome: Equatable, Sendable {
    case verified(VerifiedAccountSnapshot)
    case conflict
    case unknown
}

public enum ScriptDeletionOutcome: Equatable, Sendable {
    case verified(VerifiedAccountSnapshot)
    case unknown
}

public enum SieveAccountServiceError: Error, Equatable, Sendable {
    /// The server lacks required Sieve extensions. `missing` names them in `vacation`, `date`, `relational`
    /// order (all three when the capability list is not authoritative).
    case unsupportedCapabilities(missing: [String])
    case nameGenerationFailed
    case manifest
    /// `CHECKSCRIPT` or `PUTSCRIPT` answered `NO`: the server refused the candidate. Nothing was activated.
    case scriptRejected
    /// `CHECKSCRIPT` or `PUTSCRIPT` answered `NO` with a `QUOTA` response code. Nothing was activated.
    case quotaExceeded
    /// `SETACTIVE` answered `NO`: a definite refusal, so this operation did not change the active script.
    case activationRejected
    /// Deactivating the selected active script was definitely refused, so deletion was not attempted.
    case scriptDeactivationRejected
    /// `DELETESCRIPT` was definitely refused. `deactivated` says whether this operation had already
    /// deactivated the selected script, leaving it stored but inactive.
    case scriptDeletionRejected(deactivated: Bool)
}

public actor SieveAccountService {
    private let sessionProvider: any ManageSieveSessionProviding
    private let manifestStore: any OwnedScriptManifestStoring
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable () -> Data
    private let makeUUID: @Sendable () -> UUID

    public init(sessionProvider: any ManageSieveSessionProviding, manifestStore: any OwnedScriptManifestStoring) {
        self.init(sessionProvider: sessionProvider, manifestStore: manifestStore,
                  now: { Date() }, randomBytes: { SieveAccountService.secureRandomBytes() }, makeUUID: { UUID() })
    }

    internal init(sessionProvider: any ManageSieveSessionProviding, manifestStore: any OwnedScriptManifestStoring,
                  now: @escaping @Sendable () -> Date,
                  randomBytes: @escaping @Sendable () -> Data,
                  makeUUID: @escaping @Sendable () -> UUID) {
        self.sessionProvider = sessionProvider
        self.manifestStore = manifestStore
        self.now = now
        self.randomBytes = randomBytes
        self.makeUUID = makeUUID
    }

    public func refresh(account: AccountConfiguration) async throws -> VerifiedAccountSnapshot {
        let now = self.now
        return try await sessionProvider.withAuthenticatedSession(account: account) { session in
            let capabilities = await session.capabilities
            try Self.requireCapabilities(capabilities)
            return try await Self.verifiedSnapshot(session: session, capabilities: capabilities,
                                                   accountID: account.accountID, now: now())
        }
    }

    /// Fetches one named script with `GETSCRIPT`. Does not activate it or rewrite it.
    public func getScript(account: AccountConfiguration, name: String) async throws -> Data {
        try await sessionProvider.withAuthenticatedSession(account: account) { session in
            try await session.getScript(name: name, timeout: nil)
        }
    }

    public func deleteScript(account: AccountConfiguration, name: String) async throws -> ScriptDeletionOutcome {
        let now = self.now
        return try await sessionProvider.withAuthenticatedSession(account: account) { session in
            let capabilities = await session.capabilities
            try Self.requireCapabilities(capabilities)
            let entries = try await session.listScripts(timeout: nil)
            guard let target = entries.first(where: { $0.name == name }) else {
                return try await .verified(Self.verifiedSnapshot(session: session, entries: entries,
                    capabilities: capabilities, accountID: account.accountID, now: now()))
            }

            let wasDeactivated = target.isActive
            if wasDeactivated {
                do { try await session.setActive(name: "", timeout: nil) }
                catch {
                    if Self.isAmbiguous(error) { return .unknown }
                    if Self.isDefiniteRejection(error) { throw SieveAccountServiceError.scriptDeactivationRejected }
                    throw error
                }
            }

            do { try await session.deleteScript(name: name, timeout: nil) }
            catch {
                if Self.isAmbiguous(error) { return .unknown }
                if Self.isDefiniteRejection(error) {
                    throw SieveAccountServiceError.scriptDeletionRejected(deactivated: wasDeactivated)
                }
                throw error
            }

            do {
                return try await .verified(Self.verifiedSnapshot(session: session, capabilities: capabilities,
                    accountID: account.accountID, now: now()))
            } catch {
                return .unknown
            }
        }
    }

    public func applyOutOfOffice(account: AccountConfiguration,
                                 configuration: OutOfOfficeConfiguration?) async throws -> AccountMutationOutcome {
        let now = self.now
        let randomBytes = self.randomBytes
        let makeUUID = self.makeUUID
        let manifestStore = self.manifestStore
        return try await sessionProvider.withAuthenticatedSession(account: account) { session in
            let capabilities = await session.capabilities
            try Self.requireCapabilities(capabilities)
            let initialEntries = try await session.listScripts(timeout: nil)
            let baselineName = initialEntries.first(where: \.isActive)?.name
            let baseline: Data
            if let baselineName { baseline = try await session.getScript(name: baselineName, timeout: nil) }
            else { baseline = Data() }
            let baselineDigest = Self.sha256(baseline)
            let metadata = try ManagedScriptMetadata(accountID: account.accountID, versionID: makeUUID(),
                                                     predecessorSHA256: baselineName == nil ? nil : baselineDigest)
            let mutation: SieveScriptMutation = configuration.map(SieveScriptMutation.enable) ?? .disable
            let candidate = try SieveScriptPatcher.apply(mutation, to: baseline, metadata: metadata, accountID: account.accountID)
            // RFC 5804 defines no CHECKSCRIPT capability; a server that advertises VERSION implements the
            // command (§1.7). An authoritative capability list always carries VERSION, so this runs for
            // every server the client accepts.
            if capabilities.containsCapability("VERSION") {
                do { _ = try await session.checkScript(candidate, timeout: nil) }
                catch { throw Self.candidateRejection(error) }
            }
            let allNames = Set(initialEntries.map(\.name))
            let name = try Self.uniqueName(accountID: account.accountID, existing: allNames, randomBytes: randomBytes)
            let createdAt = now()
            let prepared = OwnedScriptManifestRecord(accountID: account.accountID, name: name,
                sha256: Self.sha256(candidate), predecessorName: baselineName,
                predecessorSHA256: baselineName == nil ? nil : baselineDigest, phase: .prepared, createdAt: createdAt)
            do { try await manifestStore.save(prepared) }
            catch { throw SieveAccountServiceError.manifest }

            do { _ = try await session.putScript(name: name, script: candidate, timeout: nil) }
            catch { throw Self.candidateRejection(error) }
            do { try await manifestStore.save(prepared.withPhase(.uploaded)) }
            catch { return .unknown }

            let repeatedEntries = try await session.listScripts(timeout: nil)
            let repeatedActive = repeatedEntries.first(where: \.isActive)?.name
            guard repeatedActive == baselineName else { return .conflict }
            if let repeatedActive {
                let repeatedBytes = try await session.getScript(name: repeatedActive, timeout: nil)
                guard Self.sha256(repeatedBytes) == baselineDigest else { return .conflict }
            }

            // ManageSieve has no compare-and-swap activation; state can still change after this final check.
            do { try await session.setActive(name: name, timeout: nil) }
            catch {
                if Self.isAmbiguous(error) { return .unknown }
                if Self.isDefiniteRejection(error) { throw SieveAccountServiceError.activationRejected }
                throw error
            }
            do {
                let verifiedEntries = try await session.listScripts(timeout: nil)
                guard verifiedEntries.first(where: \.isActive)?.name == name else { return .unknown }
                let readBack = try await session.getScript(name: name, timeout: nil)
                guard readBack == candidate else { return .unknown }
                do { try await manifestStore.save(prepared.withPhase(.verifiedActive)) }
                catch { return .unknown }
                let verifiedAt = now()
                let snapshot = VerifiedAccountSnapshot(activeScriptName: name, activeScript: readBack,
                    scripts: verifiedEntries,
                    outOfOfficeState: Self.verifiedState(script: readBack, accountID: account.accountID, now: verifiedAt),
                    verifiedAt: verifiedAt, capabilities: capabilities)
                return .verified(snapshot)
            } catch {
                return .unknown
            }
        }
    }

    private static func verifiedSnapshot(
        session: any AuthenticatedManageSieveSession,
        capabilities: ManageSieveCapabilities,
        accountID: AccountID,
        now: Date
    ) async throws -> VerifiedAccountSnapshot {
        let entries = try await session.listScripts(timeout: nil)
        return try await verifiedSnapshot(session: session, entries: entries, capabilities: capabilities,
                                          accountID: accountID, now: now)
    }

    private static func verifiedSnapshot(
        session: any AuthenticatedManageSieveSession,
        entries: [ManageSieveScriptEntry],
        capabilities: ManageSieveCapabilities,
        accountID: AccountID,
        now: Date
    ) async throws -> VerifiedAccountSnapshot {
        let activeName = entries.first(where: \.isActive)?.name
        let activeScript: Data?
        if let activeName { activeScript = try await session.getScript(name: activeName, timeout: nil) }
        else { activeScript = nil }
        let state = verifiedState(script: activeScript, accountID: accountID, now: now)
        return VerifiedAccountSnapshot(activeScriptName: activeName, activeScript: activeScript, scripts: entries,
            outOfOfficeState: state, verifiedAt: now, capabilities: capabilities)
    }

    private static func uniqueName(accountID: AccountID, existing: Set<String>,
                                   randomBytes: @Sendable () -> Data) throws -> String {
        for _ in 0..<32 {
            let bytes = randomBytes()
            guard !bytes.isEmpty else { continue }
            let suffix = bytes.map { String(format: "%02x", $0) }.joined()
            let name = "sievepilot-\(accountID.sieveToken)-\(suffix)"
            if !existing.contains(name) { return name }
        }
        throw SieveAccountServiceError.nameGenerationFailed
    }

    private static let requiredExtensions = ["vacation", "date", "relational"]

    private static func requireCapabilities(_ capabilities: ManageSieveCapabilities) throws {
        guard capabilities.isAuthoritative else {
            throw SieveAccountServiceError.unsupportedCapabilities(missing: requiredExtensions)
        }
        let missing = requiredExtensions.filter { !capabilities.supportsSieveExtension($0) }
        guard missing.isEmpty else { throw SieveAccountServiceError.unsupportedCapabilities(missing: missing) }
    }

    private static func verifiedState(script: Data?, accountID: AccountID, now: Date) -> VerifiedOutOfOfficeState {
        if let script {
            do {
                let sections = try ManagedSectionParser.parse(script, preamble: SievePreambleScanner.scan(script))
                if let range = sections.metadata {
                    let metadata = try ManagedScriptMetadataParser.parse(Data(script[range]))
                    guard metadata.accountID == accountID else { return .malformed(reason: "accountIDMismatch") }
                }
            } catch {
                return .malformed(reason: String(describing: error))
            }
        }
        return OutOfOfficeStateEvaluator.evaluate(activeScript: script, now: now)
    }

    internal static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Names the stage of a definite `NO` to `CHECKSCRIPT` or `PUTSCRIPT`; every other error passes through.
    private static func candidateRejection(_ error: Error) -> Error {
        switch error as? ManageSieveClientError {
        case .serverNo: return SieveAccountServiceError.scriptRejected
        case .quotaExceeded: return SieveAccountServiceError.quotaExceeded
        default: return error
        }
    }

    private static func isDefiniteRejection(_ error: Error) -> Bool {
        guard let error = error as? ManageSieveClientError else { return false }
        return error == .serverNo || error == .quotaExceeded
    }

    private static func isAmbiguous(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? ManageSieveClientError else { return false }
        return [.cancelled, .transport, .tls, .tlsTrustFailed, .tlsIdentityFailed, .timeout,
                .unexpectedEOF, .parse, .serverBye].contains(error)
    }

    private static func secureRandomBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return Data() }
        return Data(bytes)
    }
}
