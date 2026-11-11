import Foundation
import XCTest
import SievePilotCore
@testable import SievePilot

private actor AppSettingsStore: AccountConfigurationStoring {
    var value: AccountConfiguration?
    init(_ value: AccountConfiguration? = nil) { self.value = value }
    func load() async throws -> AccountConfiguration? { value }
    func save(_ configuration: AccountConfiguration) async throws { value = configuration }
    func delete() async throws { value = nil }
}

private actor AppPersistence: AccountPersistenceCoordinating {
    var saves: [(AccountConfiguration, Data)] = []
    var deletes: [AccountID] = []
    var error: Error?
    func save(configuration: AccountConfiguration, password: Data) async throws {
        if let error { throw error }; saves.append((configuration, password))
    }
    func delete(accountID: AccountID) async throws { if let error { throw error }; deletes.append(accountID) }
    func saveCount() -> Int { saves.count }
    func deletedIDs() -> [AccountID] { deletes }
}

private actor AppDiscovery: SieveServiceDiscovering {
    var endpoints: [SieveServiceEndpoint] = []
    var emails: [String] = []
    var error: Error?
    func discover(emailAddress: String) async throws -> SieveServiceEndpoint {
        emails.append(emailAddress); if let error { throw error }
        return endpoints.removeFirst()
    }
    func enqueue(_ endpoint: SieveServiceEndpoint) { endpoints.append(endpoint) }
}

private actor AppSessionProvider: ManageSieveSessionProviding {
    var calls = 0
    var error: Error?
    func withAuthenticatedSession<T: Sendable>(account: AccountConfiguration,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T) async throws -> T {
        calls += 1
        if let error { throw error }
        return try await operation(AppSession())
    }
    func callCount() -> Int { calls }
}

private struct AppSession: AuthenticatedManageSieveSession {
    let capabilities: ManageSieveCapabilities
    init() {
        let lines = ["IMPLEMENTATION", "VERSION", "SASL", "SIEVE"].map {
            ManageSieveWireLine(tokens: [.string(Data($0.utf8)), .string(Data(($0 == "SIEVE" ? "vacation date relational" : "test").utf8))])
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

private actor AppService: SieveAccountServicing {
    var snapshots: [VerifiedAccountSnapshot] = []
    var error: Error?
    var delay: UInt64 = 0
    func refresh(account: AccountConfiguration) async throws -> VerifiedAccountSnapshot {
        if let error { throw error }
        let snapshot = snapshots.removeFirst()
        let currentDelay = delay
        if currentDelay > 0 { try await Task.sleep(nanoseconds: currentDelay) }
        return snapshot
    }
    func enqueue(_ snapshot: VerifiedAccountSnapshot) { snapshots.append(snapshot) }
    func applyOutOfOffice(account: AccountConfiguration, configuration: OutOfOfficeConfiguration?) async throws -> AccountMutationOutcome { .unknown }
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
                       service: AppService = AppService()) -> AppModel {
        AppModel(settingsStore: settings, persistence: persistence, discovery: discovery,
                 sessionProvider: sessions, accountService: service, now: { Date(timeIntervalSince1970: 200) })
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

private extension AppSessionProvider {
    func setError(_ value: Error?) { error = value }
}
private extension AppService {
    func setError(_ value: Error?) { error = value }
    func setDelay(_ value: UInt64) { delay = value }
}
