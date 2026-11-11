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
    var checkError: Error?
    var corruptReadBack = false

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
        events.append("get:\(name)")
        if corruptReadBack, name == active, events.contains("active:\(name)") { return Data("corrupt".utf8) }
        return scripts[name] ?? Data()
    }
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult {
        events.append("check")
        if let checkError { throw checkError }
        return .init(responseCode: nil, message: nil)
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
    var savedPhases: [OwnedScriptManifestPhase] = []
    var failPhase: OwnedScriptManifestPhase?
    func load(accountID: AccountID) async throws -> [OwnedScriptManifestRecord] { records.filter { $0.accountID == accountID } }
    func save(_ record: OwnedScriptManifestRecord) async throws {
        savedPhases.append(record.phase)
        if record.phase == failPhase { throw CocoaError(.fileWriteUnknown) }
        records.removeAll { $0.accountID == record.accountID && $0.name == record.name }
        records.append(record)
    }
}

final class SieveAccountServiceTests: XCTestCase {
    private let accountID = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func capabilities(extensions: String = "vacation date relational") throws -> ManageSieveCapabilities {
        let lines = [
            ManageSieveWireLine(tokens: [.string(Data("IMPLEMENTATION".utf8)), .string(Data("test".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("VERSION".utf8)), .string(Data("1.0".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("SASL".utf8)), .string(Data("PLAIN".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("SIEVE".utf8)), .string(Data(extensions.utf8))])
        ]
        return try ManageSieveCapabilities(response: ManageSieveCommandResponse(lines: lines + [.init(tokens: [.atom("OK")])]), origin: .postTLSCapability)
    }

    private func account() throws -> AccountConfiguration {
        try AccountConfiguration(accountID: accountID, emailAddress: "user@example.org", username: "user",
                                 endpointPolicy: .automatic(sourceDomain: "example.org"), tlsPolicy: .startTLS)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SievePilot-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    func testManifestFileStoreIsVersionedPrivateAndNeverReportsFailureAfterCommit() async throws {
        let base = try temporaryDirectory()
        let record = OwnedScriptManifestRecord(accountID: accountID, name: "owned", sha256: String(repeating: "a", count: 64),
            predecessorName: "base", predecessorSHA256: String(repeating: "b", count: 64), phase: .prepared, createdAt: now)
        let store = OwnedScriptManifestStore(baseDirectory: base)
        try await store.save(record)
        let initialRecords = try await store.load(accountID: accountID)
        XCTAssertEqual(initialRecords, [record])
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: store.directoryURL.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(directoryMode.map { $0 & 0o777 }, 0o700)
        XCTAssertEqual(fileMode.map { $0 & 0o777 }, 0o600)
        let previous = try Data(contentsOf: store.fileURL)

        let failedReplace = OwnedScriptManifestStore(baseDirectory: base, replace: { _, _ in throw CocoaError(.fileWriteUnknown) })
        do { try await failedReplace.save(record.withPhase(.uploaded)); XCTFail() } catch { }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), previous)

        var attributeCalls = 0
        let noPostCommit = OwnedScriptManifestStore(baseDirectory: base, replace: OwnedScriptManifestStore.atomicReplace,
            setAttributes: { attributes, path in
                attributeCalls += 1
                if attributeCalls == 3 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
            })
        try await noPostCommit.save(record.withPhase(.uploaded))
        XCTAssertEqual(attributeCalls, 2)
        let uploadedRecords = try await store.load(accountID: accountID)
        XCTAssertEqual(uploadedRecords.first?.phase, .uploaded)

        try Data("{\"version\":2,\"records\":[]}".utf8).write(to: store.fileURL)
        do { _ = try await store.load(accountID: accountID); XCTFail() }
        catch { XCTAssertTrue(error is OwnedScriptManifestStore.ManifestStoreError) }
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

    func testRefreshVerifiesOnExpiredAndMalformedManagedScripts() async throws {
        let metadata = try ManagedScriptMetadata(accountID: accountID, versionID: UUID(), predecessorSHA256: nil)
        let onBytes = try SieveScriptPatcher.apply(.enable(configuration()), to: Data(), metadata: metadata, accountID: accountID)
        let on = ServiceSession(capabilities: try capabilities(), scripts: ["on": onBytes], active: "on")
        guard case .on = try await service(on).refresh(account: account()).outOfOfficeState else { return XCTFail() }

        let expiredConfiguration = try OutOfOfficeConfiguration(emailAddress: "user@example.org", subject: nil, message: "Expired",
            expiry: .init(instant: now.addingTimeInterval(-1), timeZoneIdentifier: "UTC", utcOffsetSeconds: 0))
        let expiredBytes = try SieveScriptPatcher.apply(.enable(expiredConfiguration), to: Data(), metadata: metadata, accountID: accountID)
        let expired = ServiceSession(capabilities: try capabilities(), scripts: ["expired": expiredBytes], active: "expired")
        guard case .expiryPassedServerClockApplies = try await service(expired).refresh(account: account()).outOfOfficeState else { return XCTFail() }

        let malformedBytes = Data("# BEGIN SIEVEPILOT METADATA v1\ninvalid\n".utf8)
        let malformed = ServiceSession(capabilities: try capabilities(), scripts: ["bad": malformedBytes], active: "bad")
        guard case .malformed = try await service(malformed).refresh(account: account()).outOfOfficeState else { return XCTFail() }
    }

    func testRefreshRejectsUnsupportedRequiredSieveExtensionsNamingEachMissingOne() async throws {
        for (extensions, missing) in [
            ("vacation", ["date", "relational"]),
            ("date relational", ["vacation"]),
            ("vacation date", ["relational"]),
            ("vacation relational", ["date"]),
            ("fileinto", ["vacation", "date", "relational"])
        ] {
            let session = ServiceSession(capabilities: try capabilities(extensions: extensions))
            do { _ = try await service(session).refresh(account: account()); XCTFail(extensions) }
            catch { XCTAssertEqual(error as? SieveAccountServiceError, .unsupportedCapabilities(missing: missing), extensions) }
        }
    }

    func testApplyFailsClosedNamingMissingExtensionsWithoutUploadOrActivation() async throws {
        for (extensions, missing) in [("date relational", ["vacation"]), ("vacation", ["date", "relational"])] {
            let session = ServiceSession(capabilities: try capabilities(extensions: extensions), scripts: ["base": Data("keep;\n".utf8)], active: "base")
            let manifests = MemoryManifestStore()
            do { _ = try await service(session, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail(extensions) }
            catch { XCTAssertEqual(error as? SieveAccountServiceError, .unsupportedCapabilities(missing: missing), extensions) }
            let events = await session.events
            XCTAssertFalse(events.contains { $0.hasPrefix("put:") || $0.hasPrefix("active:") }, extensions)
            let records = await manifests.records
            XCTAssertTrue(records.isEmpty, extensions)
        }
    }

    func testMutationUsesRawBaselineCheckScriptCollisionRetryManifestPhasesAndReadBack() async throws {
        let baseline = Data([0xff, 0x00, 0x0a])
        let collision = "sievepilot-\(accountID.sieveToken)-01020304"
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline, collision: Data("owned".utf8)], active: "base")
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

    // RFC 5804 defines no CHECKSCRIPT capability: any server advertising VERSION supports the command.
    func testCheckScriptIsSentBeforeUploadWheneverTheServerAdvertisesVersion() async throws {
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": Data("keep;\n".utf8)], active: "base")
        let outcome = try await service(session).applyOutOfOffice(account: account(), configuration: configuration())
        guard case .verified = outcome else { return XCTFail("Expected verified") }
        let events = await session.events
        let check = try XCTUnwrap(events.firstIndex(of: "check"), "CHECKSCRIPT must be sent to a VERSION-advertising server")
        let put = try XCTUnwrap(events.firstIndex { $0.hasPrefix("put:") })
        XCTAssertLessThan(check, put, "Validation must precede the upload")
        XCTAssertEqual(events.filter { $0 == "check" }.count, 1)
    }

    func testMutationConflictStopsBeforeActivation() async throws {
        let baseline = Data("keep;\n".utf8)
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        await session.setConflictOnSecondList(name: "base", script: Data("changed".utf8))
        let outcome = try await service(session).applyOutOfOffice(account: account(), configuration: configuration())
        XCTAssertEqual(outcome, .conflict)
        let events = await session.events
        XCTAssertFalse(events.contains { $0.hasPrefix("active:") })
    }

    func testAmbiguousActivationAndManifestFailureAfterActivationReturnUnknown() async throws {
        let baseline = Data("keep;\n".utf8)
        for error in [ManageSieveClientError.transport, .parse] {
            let interrupted = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
            await interrupted.setSetActiveError(error)
            let interruptedOutcome = try await service(interrupted).applyOutOfOffice(account: account(), configuration: configuration())
            XCTAssertEqual(interruptedOutcome, .unknown)
        }
        // A definite SETACTIVE refusal is an activation failure, distinct from validation and from unknown.
        let rejected = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        await rejected.setSetActiveError(ManageSieveClientError.serverNo)
        do { _ = try await service(rejected).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail() }
        catch { XCTAssertEqual(error as? SieveAccountServiceError, .activationRejected) }
        let stillActive = await rejected.active
        XCTAssertEqual(stillActive, "base")

        let manifests = MemoryManifestStore(); await manifests.setFailPhase(.verifiedActive)
        let activated = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        let manifestOutcome = try await service(activated, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration())
        XCTAssertEqual(manifestOutcome, .unknown)
        let records = await manifests.records
        XCTAssertEqual(records.map(\.phase), [.uploaded])
    }

    func testReadBackMismatchAndPreparedOrUploadedManifestFailuresAreSafe() async throws {
        let baseline = Data("keep;\n".utf8)
        let mismatch = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
        await mismatch.setCorruptReadBack(true)
        let mismatchOutcome = try await service(mismatch).applyOutOfOffice(account: account(), configuration: configuration())
        XCTAssertEqual(mismatchOutcome, .unknown)

        for phase in [OwnedScriptManifestPhase.prepared, .uploaded] {
            let manifests = MemoryManifestStore(); await manifests.setFailPhase(phase)
            let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": baseline], active: "base")
            do {
                let outcome = try await service(session, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration())
                XCTAssertEqual(phase, .uploaded); XCTAssertEqual(outcome, .unknown)
            } catch {
                XCTAssertEqual(phase, .prepared); XCTAssertEqual(error as? SieveAccountServiceError, .manifest)
            }
            let phases = await manifests.savedPhases
            XCTAssertTrue(phases.contains(phase))
        }
    }

    func testPutServerNoIsValidationFailureAndLeavesPreparedRollbackRecord() async throws {
        let manifests = MemoryManifestStore()
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": Data("keep;\n".utf8)], active: "base")
        await session.setPutError(ManageSieveClientError.serverNo)
        do { _ = try await service(session, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail() }
        catch { XCTAssertEqual(error as? SieveAccountServiceError, .scriptRejected) }
        let records = await manifests.records
        XCTAssertEqual(records.map(\.phase), [.prepared])
        let events = await session.events
        XCTAssertFalse(events.contains { $0.hasPrefix("active:") })
    }

    func testCheckScriptRejectionIsValidationFailureBeforeAnyUploadOrManifestRecord() async throws {
        let manifests = MemoryManifestStore()
        let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": Data("keep;\n".utf8)], active: "base")
        await session.setCheckError(ManageSieveClientError.serverNo)
        do { _ = try await service(session, manifests: manifests).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail() }
        catch { XCTAssertEqual(error as? SieveAccountServiceError, .scriptRejected) }
        let events = await session.events
        XCTAssertFalse(events.contains { $0.hasPrefix("put:") || $0.hasPrefix("active:") })
        let records = await manifests.records
        XCTAssertTrue(records.isEmpty)
    }

    func testQuotaRejectionStaysDistinctFromValidationAndNeverActivates() async throws {
        for stage in ["check", "put"] {
            let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": Data("keep;\n".utf8)], active: "base")
            if stage == "check" { await session.setCheckError(ManageSieveClientError.quotaExceeded) }
            else { await session.setPutError(ManageSieveClientError.quotaExceeded) }
            do { _ = try await service(session).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail(stage) }
            catch { XCTAssertEqual(error as? SieveAccountServiceError, .quotaExceeded, stage) }
            let events = await session.events
            XCTAssertFalse(events.contains { $0.hasPrefix("active:") }, stage)
            let active = await session.active
            XCTAssertEqual(active, "base", stage)
        }
    }

    func testIndefiniteUploadFailuresKeepTheirTransportClassification() async throws {
        for error in [ManageSieveClientError.transport, .timeout, .serverBye] {
            let session = ServiceSession(capabilities: try capabilities(), scripts: ["base": Data("keep;\n".utf8)], active: "base")
            await session.setPutError(error)
            do { _ = try await service(session).applyOutOfOffice(account: account(), configuration: configuration()); XCTFail() }
            catch let thrown { XCTAssertEqual(thrown as? ManageSieveClientError, error) }
        }
    }
}

private extension ServiceSession {
    func setConflictOnSecondList(name: String, script: Data) { conflictOnSecondList = (name, script) }
    func setSetActiveError(_ error: Error?) { setActiveError = error }
    func setPutError(_ error: Error?) { putError = error }
    func setCheckError(_ error: Error?) { checkError = error }
    func setCorruptReadBack(_ value: Bool) { corruptReadBack = value }
}

private extension MemoryManifestStore {
    func setFailPhase(_ phase: OwnedScriptManifestPhase?) { failPhase = phase }
}
