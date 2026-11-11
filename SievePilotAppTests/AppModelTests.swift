import Foundation
import XCTest
import SievePilotCore
@testable import SievePilot

actor AppSettingsStore: AccountConfigurationStoring {
    var value: AccountConfiguration?
    init(_ value: AccountConfiguration? = nil) { self.value = value }
    func load() async throws -> AccountConfiguration? { value }
    func save(_ configuration: AccountConfiguration) async throws { value = configuration }
    func delete() async throws { value = nil }
}

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Intentionally ignores task cancellation, like an uncooperative dependency.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

actor AppPersistence: AccountPersistenceCoordinating {
    var saves: [(AccountConfiguration, Data)] = []
    var deletes: [AccountID] = []
    var error: Error?
    var gate: Gate?
    var started = 0
    func save(configuration: AccountConfiguration, password: Data) async throws {
        started += 1
        await gate?.wait()
        if let error { throw error }; saves.append((configuration, password))
    }
    func delete(accountID: AccountID) async throws {
        started += 1
        await gate?.wait()
        if let error { throw error }; deletes.append(accountID)
    }
    func saveCount() -> Int { saves.count }
    func savedPasswords() -> [String] { saves.map { String(decoding: $0.1, as: UTF8.self) } }
    func deletedIDs() -> [AccountID] { deletes }
    func startedCount() -> Int { started }
    func setGate(_ value: Gate?) { gate = value }
}

actor AppDiscovery: SieveServiceDiscovering {
    var endpoints: [SieveServiceEndpoint] = []
    var emails: [String] = []
    var error: Error?
    func discover(emailAddress: String) async throws -> SieveServiceEndpoint {
        emails.append(emailAddress); if let error { throw error }
        return endpoints.removeFirst()
    }
    func enqueue(_ endpoint: SieveServiceEndpoint) { endpoints.append(endpoint) }
}

/// Stands in for the production factory's candidate-credential path: it can only see the
/// password handed to it, never a stored credential, and rejects anything but `accepted`.
actor AppSessionProvider: ManageSieveCandidateSessionProviding {
    var calls: [(AccountID, String)] = []
    var accepted: String?
    var error: Error?
    var nextGate: Gate?
    func withAuthenticatedSession<T: Sendable>(account: AccountConfiguration, password: Data,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T) async throws -> T {
        let candidate = String(decoding: password, as: UTF8.self)
        calls.append((account.accountID, candidate))
        let gate = nextGate; nextGate = nil
        await gate?.wait()
        if let error { throw error }
        if let accepted, accepted != candidate { throw ManageSieveClientError.serverNo }
        return try await operation(AppSession())
    }
    func callCount() -> Int { calls.count }
    func candidates() -> [String] { calls.map(\.1) }
}

struct AppSession: AuthenticatedManageSieveSession {
    let capabilities: ManageSieveCapabilities
    init(sieve: String = "vacation date relational") {
        let lines = ["IMPLEMENTATION", "VERSION", "SASL", "SIEVE"].map {
            ManageSieveWireLine(tokens: [.string(Data($0.utf8)), .string(Data(($0 == "SIEVE" ? sieve : "test").utf8))])
        }
        capabilities = try! ManageSieveCapabilities(response: ManageSieveCommandResponse(lines: lines + [.init(tokens: [.atom("OK")])]), origin: .postTLSCapability)
    }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry] { [] }
    func getScript(name: String, timeout: Duration?) async throws -> Data { Data() }
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { .init(responseCode: nil, message: nil) }
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { .init(responseCode: nil, message: nil) }
    func setActive(name: String, timeout: Duration?) async throws {}
    func deleteScript(name: String, timeout: Duration?) async throws {}
}

actor AppService: SieveAccountServicing {
    var snapshots: [VerifiedAccountSnapshot] = []
    var error: Error?
    var delay: UInt64 = 0
    var gate: Gate?
    var refreshCount = 0
    var applyOutcomes: [Result<AccountMutationOutcome, Error>] = []
    var applied: [OutOfOfficeConfiguration?] = []
    var applyGate: Gate?
    func refresh(account: AccountConfiguration) async throws -> VerifiedAccountSnapshot {
        refreshCount += 1
        if let error { throw error }
        guard !snapshots.isEmpty else { throw NSError(domain: "no-snapshot", code: 1) }
        // Claimed at call time so concurrent calls get deterministic, ordered snapshots.
        let snapshot = snapshots.removeFirst()
        await gate?.wait()
        let currentDelay = delay
        if currentDelay > 0 { try await Task.sleep(nanoseconds: currentDelay) }
        return snapshot
    }
    func enqueue(_ snapshot: VerifiedAccountSnapshot) { snapshots.append(snapshot) }
    func applyOutOfOffice(account: AccountConfiguration, configuration: OutOfOfficeConfiguration?) async throws -> AccountMutationOutcome {
        applied.append(configuration)
        await applyGate?.wait()
        guard !applyOutcomes.isEmpty else { return .unknown }
        return try applyOutcomes.removeFirst().get()
    }
    func enqueueOutcome(_ outcome: Result<AccountMutationOutcome, Error>) { applyOutcomes.append(outcome) }
    func appliedConfigurations() -> [OutOfOfficeConfiguration?] { applied }
    func refreshCalls() -> Int { refreshCount }
    func setApplyGate(_ value: Gate?) { applyGate = value }
}

@MainActor
final class FakeLifecycle: AppLifecycleObserving {
    private(set) var handler: (@MainActor @Sendable (AppLifecycleEvent) -> Void)?
    func start(_ handler: @escaping @MainActor @Sendable (AppLifecycleEvent) -> Void) { self.handler = handler }
    func send(_ event: AppLifecycleEvent) { handler?(event) }
}

@MainActor
final class AppModelTests: XCTestCase {
    private let id = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)

    private func account(manual: Bool = false) throws -> AccountConfiguration {
        try AccountConfiguration(accountID: id, emailAddress: "user@example.org", username: "user",
            endpointPolicy: manual ? .manual(host: "mail.example.org", port: 4190) : .automatic(sourceDomain: "example.org"), tlsPolicy: .startTLS)
    }

    private func snapshot(_ date: Date = Date(timeIntervalSince1970: 100)) throws -> VerifiedAccountSnapshot {
        let session = AppSession()
        return VerifiedAccountSnapshot(activeScriptName: nil, activeScript: nil, outOfOfficeState: .off,
                                       verifiedAt: date, capabilities: session.capabilities)
    }

    private func model(settings: AppSettingsStore = AppSettingsStore(), persistence: AppPersistence = AppPersistence(),
                       discovery: AppDiscovery = AppDiscovery(), sessions: AppSessionProvider = AppSessionProvider(),
                       service: AppService = AppService(), lifecycle: (any AppLifecycleObserving)? = nil) -> AppModel {
        AppModel(settingsStore: settings, persistence: persistence, discovery: discovery,
                 sessionProvider: sessions, accountService: service, now: { Date(timeIntervalSince1970: 200) },
                 calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0)!, lifecycle: lifecycle)
    }

    private func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func fillManual(_ model: AppModel, password: String = "secret") {
        model.emailAddress = "user@example.org"; model.username = "user"; model.password = password
        model.usesAutomaticDiscovery = false; model.manualHost = "mail.example.org"; model.manualPort = "4190"
    }

    func testFirstRunAndLoadingExistingAccountPopulateSetup() async throws {
        let first = model()
        await first.load()
        XCTAssertNil(first.persistedAccount); XCTAssertEqual(first.operationState, .idle)

        let settings = AppSettingsStore(try account(manual: true))
        let existing = model(settings: settings)
        await existing.load()
        XCTAssertEqual(existing.persistedAccount, try account(manual: true))
        XCTAssertEqual(existing.emailAddress, "user@example.org")
        XCTAssertFalse(existing.usesAutomaticDiscovery)
        XCTAssertEqual(existing.manualHost, "mail.example.org")
        XCTAssertEqual(existing.manualPort, "4190")
        XCTAssertEqual(existing.operationState, .stale)
    }

    func testAutomaticDiscoveryPreviewAndSuccessfulTestSave() async throws {
        let persistence = AppPersistence(), discovery = AppDiscovery(), sessions = AppSessionProvider()
        await discovery.enqueue(.init(host: "srv.example.net", port: 4190, referenceIdentifiers: [.dns("example.org")]))
        let model = model(persistence: persistence, discovery: discovery, sessions: sessions)
        model.emailAddress = "user@example.org"; model.username = "user"; model.password = "secret"
        await model.testAndSave()
        XCTAssertEqual(model.discoveryPreview, "srv.example.net:4190")
        XCTAssertEqual(model.persistedAccount?.endpointPolicy, .automatic(sourceDomain: "example.org"))
        XCTAssertEqual(model.operationState, .stale)
        XCTAssertEqual(model.password, "")
        let saveCount = await persistence.saveCount()
        let callCount = await sessions.callCount()
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(callCount, 1)
    }

    func testManualFallbackValidationAndFailedTestNeverPersist() async throws {
        let persistence = AppPersistence(), sessions = AppSessionProvider()
        let model = model(persistence: persistence, sessions: sessions)
        model.emailAddress = "bad"; model.username = ""; model.password = "secret"
        await model.testAndSave()
        XCTAssertNotNil(model.userFacingError)
        let invalidSaveCount = await persistence.saveCount()
        XCTAssertEqual(invalidSaveCount, 0)

        model.emailAddress = "user@example.org"; model.username = "user"; model.usesAutomaticDiscovery = false
        model.manualHost = "mail.example.org"; model.manualPort = "4190"
        await sessions.setError(ManageSieveClientError.serverNo)
        await model.testAndSave()
        let saveCount = await persistence.saveCount()
        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(model.userFacingError?.contains("secret") ?? true)
    }

    func testRefreshTransitionsVerifiedUnknownErrorAndCancellationIsRedacted() async throws {
        let service = AppService(), settings = AppSettingsStore(try account())
        await service.enqueue(try snapshot())
        let model = model(settings: settings, service: service)
        await model.load(); await model.refresh()
        XCTAssertEqual(model.operationState, .verified); XCTAssertEqual(model.verifiedSnapshot, try snapshot())

        await service.setError(CancellationError())
        await model.refresh()
        XCTAssertEqual(model.operationState, .unknown)
        XCTAssertNil(model.userFacingError)

        await service.setError(NSError(domain: "secret-password", code: 1))
        await model.refresh()
        XCTAssertEqual(model.operationState, .error)
        XCTAssertFalse(model.userFacingError?.contains("secret-password") ?? true)
    }

    func testNewerGenerationPreventsStaleRefreshCompletion() async throws {
        let service = AppService(), settings = AppSettingsStore(try account())
        await service.setDelay(80_000_000)
        await service.enqueue(try snapshot(Date(timeIntervalSince1970: 1)))
        await service.enqueue(try snapshot(Date(timeIntervalSince1970: 2)))
        let model = model(settings: settings, service: service)
        await model.load()
        async let first: Void = model.refresh()
        try await Task.sleep(nanoseconds: 5_000_000)
        await service.setDelay(0)
        await model.refresh()
        _ = await first
        XCTAssertEqual(model.verifiedSnapshot?.verifiedAt, Date(timeIntervalSince1970: 2))
    }

    func testFirstRunTestAndSaveAuthenticatesWithFormPasswordAndFailedTestDoesNotPersist() async throws {
        let persistence = AppPersistence(), sessions = AppSessionProvider()
        await sessions.setAccepted("correct-horse")
        let model = model(persistence: persistence, sessions: sessions)
        fillManual(model, password: "wrong")
        await model.testAndSave()
        XCTAssertEqual(model.operationState, .error)
        XCTAssertNotNil(model.userFacingError)
        XCTAssertFalse(model.userFacingError?.contains("wrong") ?? true)
        XCTAssertNil(model.persistedAccount)
        XCTAssertEqual(model.password, "wrong")
        var saveCount = await persistence.saveCount()
        XCTAssertEqual(saveCount, 0)

        model.password = "correct-horse"
        await model.testAndSave()
        XCTAssertEqual(model.operationState, .stale)
        XCTAssertNil(model.userFacingError)
        XCTAssertNotNil(model.persistedAccount)
        saveCount = await persistence.saveCount()
        let saved = await persistence.savedPasswords()
        let candidates = await sessions.candidates()
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(saved, ["correct-horse"])
        XCTAssertEqual(candidates, ["wrong", "correct-horse"])
    }

    func testEditingExistingAccountTestsTheNewPasswordAndKeepsAccountID() async throws {
        let persistence = AppPersistence(), sessions = AppSessionProvider()
        await sessions.setAccepted("new-password")
        let model = model(settings: AppSettingsStore(try account(manual: true)), persistence: persistence, sessions: sessions)
        await model.load()
        model.password = "old-password"
        await model.testAndSave()
        XCTAssertEqual(model.operationState, .error)
        var saveCount = await persistence.saveCount()
        XCTAssertEqual(saveCount, 0)
        model.password = "new-password"
        await model.testAndSave()
        saveCount = await persistence.saveCount()
        let calls = await sessions.calls
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(calls.map(\.0), [id, id])
        XCTAssertEqual(model.persistedAccount?.accountID, id)
    }

    func testEmptyPasswordIsRejectedBeforeAnyNetworkOrPersistence() async throws {
        let persistence = AppPersistence(), sessions = AppSessionProvider(), discovery = AppDiscovery()
        let model = model(persistence: persistence, discovery: discovery, sessions: sessions)
        model.emailAddress = "user@example.org"; model.username = "user"; model.password = ""
        await model.testAndSave()
        XCTAssertEqual(model.operationState, .error)
        XCTAssertNotNil(model.userFacingError)
        let callCount = await sessions.callCount()
        let saveCount = await persistence.saveCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(model.persistedAccount)
    }

    func testFailedTestSetsErrorWithRedactedMessage() async throws {
        let sessions = AppSessionProvider()
        await sessions.setError(NSError(domain: "secret-sasl-payload", code: 7))
        let model = model(sessions: sessions)
        fillManual(model, password: "hunter2")
        await model.testAndSave()
        XCTAssertEqual(model.operationState, .error)
        let message = try XCTUnwrap(model.userFacingError)
        XCTAssertFalse(message.contains("secret-sasl-payload"))
        XCTAssertFalse(message.contains("hunter2"))
    }

    func testMarkStaleDuringInFlightSaveDoesNotDropPersistenceOrHangState() async throws {
        let persistence = AppPersistence(), gate = Gate()
        await persistence.setGate(gate)
        let model = model(persistence: persistence)
        fillManual(model)
        let save = Task { await model.testAndSave() }
        await eventually { await persistence.startedCount() == 1 }
        model.markStale()
        await gate.open()
        await save.value
        XCTAssertNotNil(model.persistedAccount)
        XCTAssertEqual(model.operationState, .stale)
        XCTAssertEqual(model.password, "")
        let saveCount = await persistence.saveCount()
        XCTAssertEqual(saveCount, 1)
    }

    func testMarkStaleDuringInFlightDeleteDoesNotDropPersistenceOrHangState() async throws {
        let persistence = AppPersistence(), gate = Gate()
        let model = model(settings: AppSettingsStore(try account()), persistence: persistence)
        await model.load()
        await persistence.setGate(gate)
        let delete = Task { await model.deleteAccount() }
        await eventually { await persistence.startedCount() == 1 }
        model.markStale()
        await gate.open()
        await delete.value
        XCTAssertNil(model.persistedAccount)
        XCTAssertEqual(model.operationState, .idle)
        let deleted = await persistence.deletedIDs()
        XCTAssertEqual(deleted, [id])
    }

    func testMarkStaleDuringRefreshDropsSnapshotAndLeavesStale() async throws {
        let service = AppService(), gate = Gate()
        await service.enqueue(try snapshot())
        await service.setGate(gate)
        let model = model(settings: AppSettingsStore(try account()), service: service)
        await model.load()
        let refresh = Task { await model.refresh() }
        await eventually { model.operationState == .refreshing }
        try await Task.sleep(nanoseconds: 10_000_000)
        model.markStale()
        XCTAssertEqual(model.operationState, .stale)
        await gate.open()
        await refresh.value
        XCTAssertNil(model.verifiedSnapshot)
        XCTAssertEqual(model.operationState, .stale)
    }

    func testNewerTestAndSaveSupersedesStaleCompletion() async throws {
        let persistence = AppPersistence(), sessions = AppSessionProvider(), gate = Gate()
        let model = model(persistence: persistence, sessions: sessions)
        fillManual(model, password: "first")
        await sessions.setNextGate(gate)
        let first = Task { await model.testAndSave() }
        await eventually { await sessions.callCount() == 1 }
        model.password = "second"
        await model.testAndSave()
        XCTAssertEqual(model.operationState, .stale)
        await gate.open()
        await first.value
        let saved = await persistence.savedPasswords()
        XCTAssertEqual(saved, ["second"])
        XCTAssertEqual(model.operationState, .stale)
        XCTAssertNil(model.userFacingError)
    }

    func testLifecycleBoundaryDrivesStaleAndRefresh() async throws {
        let service = AppService(), lifecycle = FakeLifecycle()
        await service.enqueue(try snapshot())
        let model = model(settings: AppSettingsStore(try account()), service: service, lifecycle: lifecycle)
        XCTAssertNotNil(lifecycle.handler)
        await model.load()
        await model.handle(.didBecomeActive)
        XCTAssertEqual(model.operationState, .verified)
        lifecycle.send(.didResignActive)
        XCTAssertEqual(model.operationState, .stale)
    }

    func testDeleteAccountClearsStateAndCredentialOwner() async throws {
        let persistence = AppPersistence(), settings = AppSettingsStore(try account())
        let model = model(settings: settings, persistence: persistence)
        await model.load(); await model.deleteAccount()
        XCTAssertNil(model.persistedAccount); XCTAssertNil(model.verifiedSnapshot)
        XCTAssertEqual(model.operationState, .idle)
        let deletedIDs = await persistence.deletedIDs()
        XCTAssertEqual(deletedIDs, [id])
    }
}

extension AppSessionProvider {
    func setError(_ value: Error?) { error = value }
    func setAccepted(_ value: String?) { accepted = value }
    func setNextGate(_ value: Gate?) { nextGate = value }
}
extension AppService {
    func setError(_ value: Error?) { error = value }
    func setDelay(_ value: UInt64) { delay = value }
    func setGate(_ value: Gate?) { gate = value }
}
