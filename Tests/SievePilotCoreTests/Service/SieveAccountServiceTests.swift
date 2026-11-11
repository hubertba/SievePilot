import Foundation
import XCTest
@testable import SievePilotCore

private actor ServiceSession: AuthenticatedManageSieveSession {
    let capabilities: ManageSieveCapabilities
    var scripts: [String: Data]
    var active: String?
    var events: [String] = []
    var listCount = 0
    var conflictOnSecondList: (String, Data)?
    var setActiveError: Error?
    var putError: Error?

    init(capabilities: ManageSieveCapabilities, scripts: [String: Data] = [:], active: String? = nil) {
        self.capabilities = capabilities; self.scripts = scripts; self.active = active
    }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry] {
        listCount += 1; events.append("list")
        if listCount == 2, let conflictOnSecondList {
            scripts[conflictOnSecondList.0] = conflictOnSecondList.1
            active = conflictOnSecondList.0
        }
        return scripts.keys.sorted().map { .init(name: $0, isActive: $0 == active) }
    }
    func getScript(name: String, timeout: Duration?) async throws -> Data {
        events.append("get:\(name)"); return scripts[name] ?? Data()
    }
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult {
        events.append("check"); return .init(responseCode: nil, message: nil)
    }
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult {
        events.append("put:\(name)")
        if let putError { throw putError }
        XCTAssertNil(scripts[name], "Service must never overwrite an existing script")
        scripts[name] = script
        return .init(responseCode: nil, message: nil)
    }
    func setActive(name: String, timeout: Duration?) async throws {
        events.append("active:\(name)")
        if let setActiveError { throw setActiveError }
        active = name
    }
    func deleteScript(name: String, timeout: Duration?) async throws { events.append("delete:\(name)"); scripts[name] = nil }
}

private struct ServiceProvider: ManageSieveSessionProviding {
    let session: ServiceSession
    func withAuthenticatedSession<T: Sendable>(account: AccountConfiguration,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T) async throws -> T {
        try await operation(session)
    }
}

private final class DrawSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]
    init(_ values: [Data]) { self.values = values }
    func next() -> Data { lock.lock(); defer { lock.unlock() }; return values.removeFirst() }
}

private actor MemoryManifestStore: OwnedScriptManifestStoring {
    var records: [OwnedScriptManifestRecord] = []
    var failPhase: OwnedScriptManifestPhase?
    func load(accountID: AccountID) async throws -> [OwnedScriptManifestRecord] { records.filter { $0.accountID == accountID } }
    func save(_ record: OwnedScriptManifestRecord) async throws {
        if record.phase == failPhase { throw CocoaError(.fileWriteUnknown) }
        records.removeAll { $0.accountID == record.accountID && $0.name == record.name }
        records.append(record)
    }
}

final class SieveAccountServiceTests: XCTestCase {
    private let accountID = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func capabilities(checkScript: Bool = false, extensions: String = "vacation date relational") throws -> ManageSieveCapabilities {
        var lines = [
            ManageSieveWireLine(tokens: [.string(Data("IMPLEMENTATION".utf8)), .string(Data("test".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("VERSION".utf8)), .string(Data("1".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("SASL".utf8)), .string(Data("PLAIN".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("SIEVE".utf8)), .string(Data(extensions.utf8))])
        ]
        if checkScript { lines.append(ManageSieveWireLine(tokens: [.string(Data("CHECKSCRIPT".utf8))])) }
        return try ManageSieveCapabilities(response: ManageSieveCommandResponse(lines: lines + [.init(tokens: [.atom("OK")])]), origin: .postTLSCapability)
    }

    private func account() throws -> AccountConfiguration {
        try AccountConfiguration(accountID: accountID, emailAddress: "user@example.org", username: "user",
                                 endpointPolicy: .automatic(sourceDomain: "example.org"), tlsPolicy: .startTLS)
    }

    private func configuration() throws -> OutOfOfficeConfiguration {
        try OutOfOfficeConfiguration(emailAddress: "user@example.org", subject: "Away", message: "Back soon",
                                     expiry: .init(instant: now.addingTimeInterval(3600), timeZoneIdentifier: "UTC", utcOffsetSeconds: 0))
    }

    private func service(_ session: ServiceSession, manifests: MemoryManifestStore = MemoryManifestStore(),
                         random: @escaping @Sendable () -> Data = { Data([1, 2, 3, 4]) }) -> SieveAccountService {
        let fixedNow = now
        return SieveAccountService(sessionProvider: ServiceProvider(session: session), manifestStore: manifests,
                                   now: { fixedNow }, randomBytes: random,
                                   makeUUID: { UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")! })
    }

    func testRefreshNoActiveBinaryMalformedOwnershipAndTimestampAfterVerification() async throws {
        let empty = ServiceSession(capabilities: try capabilities())
        let snapshot = try await service(empty).refresh(account: account())
        XCTAssertNil(snapshot.activeScriptName); XCTAssertNil(snapshot.activeScript)
        XCTAssertEqual(snapshot.outOfOfficeState, .off); XCTAssertEqual(snapshot.verifiedAt, now)

        let binary = Data([0xff, 0x00, 0xfe])
        let malformed = ServiceSession(capabilities: try capabilities(), scripts: ["binary": binary], active: "binary")
        let malformedSnapshot = try await service(malformed).refresh(account: account())
        XCTAssertEqual(malformedSnapshot.activeScript, binary)
        XCTAssertEqual(malformedSnapshot.outOfOfficeState, .off)

        let otherID = AccountID(rawValue: UUID())
        let metadata = try ManagedScriptMetadata(accountID: otherID, versionID: UUID(), predecessorSHA256: nil)
        let owned = try SieveScriptPatcher.apply(.enable(configuration()), to: Data(), metadata: metadata, accountID: otherID)
        let mismatch = ServiceSession(capabilities: try capabilities(), scripts: ["owned": owned], active: "owned")
        let mismatchSnapshot = try await service(mismatch).refresh(account: account())
        XCTAssertEqual(mismatchSnapshot.outOfOfficeState, .malformed(reason: "accountIDMismatch"))
    }

    func testRefreshRejectsUnsupportedRequiredSieveExtensions() async throws {
        let session = ServiceSession(capabilities: try capabilities(extensions: "vacation"))
        do { _ = try await service(session).refresh(account: account()); XCTFail() }
        catch { XCTAssertEqual(error as? SieveAccountServiceError, .unsupportedCapabilities) }
    }

    func testMutationUsesRawBaselineCheckScriptCollisionRetryManifestPhasesAndReadBack() async throws {
        let baseline = Data([0xff, 0x00, 0x0a])
        let collision = "sievepilot-\(accountID.sieveToken)-01020304"
        let session = ServiceSession(capabilities: try capabilities(checkScript: true), scripts: ["base": baseline, collision: Data("owned".utf8)], active: "base")
        let manifests = MemoryManifestStore()
        let draws = DrawSource([Data([1,2,3,4]), Data([5,6,7,8])])
        let outcome = try await service(session, manifests: manifests, random: { draws.next() })
            .applyOutOfOffice(account: account(), configuration: configuration())
        guard case .verified(let snapshot) = outcome else { return XCTFail("Expected verified") }
        XCTAssertEqual(snapshot.outOfOfficeState, .on(configuration: .init(emailAddress: "user@example.org", subject: "Away", message: "Back soon", expiryInstant: now.addingTimeInterval(3600))))
        let events = await session.events
        XCTAssertTrue(events.contains("check"))
        XCTAssertTrue(events.contains("put:sievepilot-\(accountID.sieveToken)-05060708"))
        XCTAssertTrue(events.contains("active:sievepilot-\(accountID.sieveToken)-05060708"))
        let records = await manifests.records
        XCTAssertEqual(records.map(\.phase), [.verifiedActive])
        XCTAssertEqual(records.first?.predecessorName, "base")
        XCTAssertEqual(records.first?.predecessorSHA256, SieveAccountService.sha256(baseline))
    }

    func testMutationConflictStopsBeforeActivationAndCheckScriptIsOptional() async throws {
        let baseline = Data("keep;\n".utf8)
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        await session.setConflictOnSecondList(name: "other", script: Data("changed".utf8))
        let outcome = try await service(session).applyOutOfOffice(account: account(), configuration: configuration())
        XCTAssertEqual(outcome, .conflict)
        let events = await session.events
        XCTAssertFalse(events.contains("check"))
        XCTAssertFalse(events.contains { $0.hasPrefix("active:") })
    }

    func testAmbiguousActivationAndManifestFailureAfterActivationReturnUnknown() async throws {
        let baseline = Data("keep;\n".utf8)
        let interrupted = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        await interrupted.setSetActiveError(ManageSieveClientError.transport)
        let interruptedOutcome = try await service(interrupted).applyOutOfOffice(account: account(), configuration: configuration())
        XCTAssertEqual(interruptedOutcome, .unknown)

        let manifests = MemoryManifestStore(); await manifests.setFailPhase(.verifiedActive)
        let activated = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        let manifestOutcome = try await service(activated, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration())
        XCTAssertEqual(manifestOutcome, .unknown)
        let records = await manifests.records
        XCTAssertEqual(records.map(\.phase), [.uploaded])
    }

    func testPutServerNoPropagatesAndLeavesPreparedRollbackRecord() async throws {
        let manifests = MemoryManifestStore()
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": Data("keep;\n".utf8)], active: "base")
        await session.setPutError(ManageSieveClientError.serverNo)
        do { _ = try await service(session, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail() }
        catch { XCTAssertEqual(error as? ManageSieveClientError, .serverNo) }
        let records = await manifests.records
        XCTAssertEqual(records.map(\.phase), [.prepared])
    }
}

private extension ServiceSession {
    func setConflictOnSecondList(name: String, script: Data) { conflictOnSecondList = (name, script) }
    func setSetActiveError(_ error: Error?) { setActiveError = error }
    func setPutError(_ error: Error?) { putError = error }
}

private extension MemoryManifestStore {
    func setFailPhase(_ phase: OwnedScriptManifestPhase?) { failPhase = phase }
}
