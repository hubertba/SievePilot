import AppKit
import Foundation
import XCTest
import SievePilotCore
@testable import SievePilot

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}

@MainActor
final class FakePathMonitor: NetworkPathMonitoring {
    private(set) var handler: (@MainActor @Sendable (NetworkPathStatus) -> Void)?
    private(set) var stopCount = 0
    func start(_ handler: @escaping @MainActor @Sendable (NetworkPathStatus) -> Void) { self.handler = handler }
    func stop() { stopCount += 1 }
    func send(_ status: NetworkPathStatus) { handler?(status) }
}

@MainActor
final class OutOfOfficeFlowTests: XCTestCase {
    // 2027-01-15T08:00:00Z
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)
    private var clock: TestClock!

    override func setUp() async throws { clock = TestClock(start) }

    private func account() throws -> AccountConfiguration {
        try AccountConfiguration(accountID: id, emailAddress: "user@example.org", username: "user",
                                 endpointPolicy: .manual(host: "mail.example.org", port: 4190), tlsPolicy: .startTLS)
    }

    private func parsed(subject: String? = "Away", message: String = "Back soon",
                        expiry: TimeInterval = 1_800_100_000) -> ParsedOutOfOfficeConfiguration {
        ParsedOutOfOfficeConfiguration(emailAddress: "user@example.org", subject: subject, message: message,
                                       expiryInstant: Date(timeIntervalSince1970: expiry))
    }

    private func snapshot(_ state: VerifiedOutOfOfficeState = .off, sieve: String = "vacation date relational",
                          at verifiedAt: TimeInterval = 1_800_000_000,
                          scripts: [ManageSieveScriptEntry] = [],
                          activeScript: Data? = nil) -> VerifiedAccountSnapshot {
        VerifiedAccountSnapshot(activeScriptName: scripts.first(where: \.isActive)?.name, activeScript: activeScript,
                                scripts: scripts, outOfOfficeState: state,
                                verifiedAt: Date(timeIntervalSince1970: verifiedAt),
                                capabilities: AppSession(sieve: sieve).capabilities)
    }

    private struct Harness {
        let model: AppModel
        let service: AppService
        let persistence: AppPersistence
        let lifecycle: FakeLifecycle
        let acknowledgements: InMemoryActivationAcknowledgementStore
    }

    private func harness(acknowledged: Bool = true, delay: Duration = .zero,
                         persistence: AppPersistence = AppPersistence(),
                         sessions: AppSessionProvider = AppSessionProvider(),
                         store: InMemoryActivationAcknowledgementStore = InMemoryActivationAcknowledgementStore()) async throws -> Harness {
        let service = AppService(), lifecycle = FakeLifecycle()
        if acknowledged { store.acknowledge(id) }
        let clock = clock!
        let model = AppModel(settingsStore: AppSettingsStore(try account()), persistence: persistence,
                             discovery: AppDiscovery(), sessionProvider: sessions, accountService: service,
                             now: { clock.date }, calendar: Calendar(identifier: .gregorian),
                             timeZone: TimeZone(identifier: "Europe/Warsaw")!, lifecycle: lifecycle,
                             acknowledgements: store, refreshCoalescingDelay: delay)
        await model.load()
        return Harness(model: model, service: service, persistence: persistence, lifecycle: lifecycle, acknowledgements: store)
    }

    private func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    /// Fills a valid enabling form with a far-future expiry in Warsaw.
    private func fillValid(_ model: AppModel, subject: String = "Away", message: String = "Back soon") {
        model.subject = subject
        model.message = message
        model.expiryTimeZoneIdentifier = "Europe/Warsaw"
        model.expiryLocal = DateComponents(year: 2027, month: 2, day: 1, hour: 17, minute: 0)
    }

    // MARK: Labels and derived status

    func testStatusLabelsComeOnlyFromVerifiedSnapshots() async throws {
        let h = try await harness()
        XCTAssertEqual(h.model.outOfOfficeStatus.label, "Unknown — verification required")

        await h.service.enqueue(snapshot(.on(configuration: parsed())))
        await h.model.refresh()
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOn)
        XCTAssertEqual(h.model.outOfOfficeStatus.label, "Verified On")
        XCTAssertEqual(h.model.verifiedAt, Date(timeIntervalSince1970: 1_800_000_000))

        h.model.markStale()
        XCTAssertEqual(h.model.outOfOfficeStatus.label, "Unknown — verification required")
        XCTAssertNil(h.model.verifiedAt)

        await h.service.enqueue(snapshot(.off))
        await h.model.refresh()
        XCTAssertEqual(h.model.outOfOfficeStatus.label, "Verified Off")
        XCTAssertEqual(h.model.listedScripts, [])

        await h.service.enqueue(snapshot(.expiryPassedServerClockApplies(configuration: parsed(expiry: 10))))
        await h.model.refresh()
        XCTAssertEqual(h.model.outOfOfficeStatus.label, "Expiry passed — script verified; server clock applies")

        await h.service.enqueue(snapshot(.malformed(reason: "x")))
        await h.model.refresh()
        XCTAssertEqual(h.model.outOfOfficeStatus.label, "Unknown — verification required")
    }

    func testRefreshExposesEveryListedScriptNameAndActiveFlag() async throws {
        let h = try await harness()
        let scripts = [
            ManageSieveScriptEntry(name: "keep", isActive: false),
            ManageSieveScriptEntry(name: "sievepilot-vacation", isActive: true),
        ]
        await h.service.enqueue(snapshot(.off, scripts: scripts, activeScript: Data("require \"vacation\";\n".utf8)))
        await h.model.refresh()
        XCTAssertEqual(h.model.listedScripts, scripts)
        XCTAssertEqual(h.model.listedScripts.first(where: \.isActive)?.name, "sievepilot-vacation")
        XCTAssertEqual(h.model.selectedScriptName, "sievepilot-vacation")
        XCTAssertEqual(h.model.selectedScriptSource, "require \"vacation\";\n")
        let fetchedAfterRefresh = await h.service.scriptFetchNames()
        XCTAssertEqual(fetchedAfterRefresh, [])
    }

    func testSelectingAnotherScriptShowsItsContentAndConfiguration() async throws {
        let h = try await harness()
        let scripts = [
            ManageSieveScriptEntry(name: "keep", isActive: false),
            ManageSieveScriptEntry(name: "old-vacation", isActive: false),
            ManageSieveScriptEntry(name: "sievepilot-vacation", isActive: true),
        ]
        let active = Data("require \"vacation\";\n".utf8)
        await h.service.enqueue(snapshot(.off, scripts: scripts, activeScript: active))
        await h.model.refresh()

        await h.service.setScripts(["keep": Data("keep;\n".utf8)])
        await h.model.selectScript("keep")
        XCTAssertEqual(h.model.selectedScriptName, "keep")
        XCTAssertEqual(h.model.selectedScriptSource, "keep;\n")
        XCTAssertEqual(h.model.selectedScriptOutOfOfficeState, .off)
        XCTAssertEqual(h.model.selectedScriptEntry?.isActive, false)
        let fetchedKeep = await h.service.scriptFetchNames()
        XCTAssertEqual(fetchedKeep, ["keep"])

        let metadata = try ManagedScriptMetadata(accountID: id, versionID: UUID(), predecessorSHA256: nil)
        let managed = try OutOfOfficeConfiguration(
            emailAddress: "user@example.org", subject: "Away", message: "Back soon",
            expiry: .init(instant: Date(timeIntervalSince1970: 1_800_100_000),
                          timeZoneIdentifier: "UTC", utcOffsetSeconds: 0)
        )
        let managedBytes = try SieveScriptPatcher.apply(.enable(managed), to: Data(), metadata: metadata, accountID: id)
        await h.service.setScripts(["old-vacation": managedBytes])
        await h.model.selectScript("old-vacation")
        XCTAssertEqual(h.model.selectedScriptName, "old-vacation")
        XCTAssertEqual(h.model.selectedScriptSource, String(data: managedBytes, encoding: .utf8))
        guard case .on(let configuration) = h.model.selectedScriptOutOfOfficeState else {
            return XCTFail("expected SievePilot configuration")
        }
        XCTAssertEqual(configuration.subject, "Away")
        XCTAssertEqual(configuration.message, "Back soon")
        XCTAssertEqual(configuration.emailAddress, "user@example.org")
        XCTAssertEqual(configuration.expiryInstant, Date(timeIntervalSince1970: 1_800_100_000))

        await h.model.selectScript("sievepilot-vacation")
        XCTAssertEqual(h.model.selectedScriptSource, "require \"vacation\";\n")
        let fetchedInactive = await h.service.scriptFetchNames()
        XCTAssertEqual(fetchedInactive, ["keep", "old-vacation"])
    }

    func testSelectingAnotherScriptReportsLoadFailureWithoutClearingVerification() async throws {
        let h = try await harness()
        let scripts = [
            ManageSieveScriptEntry(name: "keep", isActive: false),
            ManageSieveScriptEntry(name: "sievepilot-vacation", isActive: true),
        ]
        await h.service.enqueue(snapshot(.off, scripts: scripts, activeScript: Data("keep;\n".utf8)))
        await h.model.refresh()
        await h.service.setGetScriptError(NSError(domain: "test", code: 1))
        await h.model.selectScript("keep")
        XCTAssertEqual(h.model.scriptInspectError, "Unable to load this script.")
        XCTAssertNil(h.model.selectedScriptBytes)
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOff)
        XCTAssertNil(h.model.userFacingError)
    }

    func testDeleteSelectedScriptAdoptsVerifiedSnapshotAndMovesOffDeletedSelection() async throws {
        let h = try await harness()
        let scripts = [
            ManageSieveScriptEntry(name: "active", isActive: true),
            ManageSieveScriptEntry(name: "old", isActive: false),
        ]
        let activeBytes = Data("keep;\n".utf8)
        await h.service.enqueue(snapshot(.off, scripts: scripts, activeScript: activeBytes))
        await h.model.refresh()
        await h.service.setScripts(["old": Data("discard;\n".utf8)])
        await h.model.selectScript("old")
        await h.service.enqueueDeletion(.success(.verified(snapshot(.off,
            scripts: [.init(name: "active", isActive: true)], activeScript: activeBytes))))

        await h.model.deleteScript(named: "old", deactivationAuthorized: false)

        let deletionNames = await h.service.deletionNames()
        XCTAssertEqual(deletionNames, ["old"])
        XCTAssertEqual(h.model.listedScripts, [.init(name: "active", isActive: true)])
        XCTAssertEqual(h.model.selectedScriptName, "active")
        XCTAssertEqual(h.model.selectedScriptSource, "keep;\n")
        XCTAssertEqual(h.model.operationState, .verified)
    }

    func testDeleteSelectedActiveScriptCanLeaveNoActiveScript() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.on(configuration: parsed()),
                                         scripts: [.init(name: "active", isActive: true)],
                                         activeScript: Data("keep;\n".utf8)))
        await h.model.refresh()
        await h.service.enqueueDeletion(.success(.verified(snapshot(.off))))

        await h.model.deleteScript(named: "active", deactivationAuthorized: true)

        XCTAssertTrue(h.model.listedScripts.isEmpty)
        XCTAssertNil(h.model.selectedScriptName)
        XCTAssertNil(h.model.selectedScriptBytes)
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOff)
    }

    func testDeleteScriptUnknownOutcomeRequiresRefresh() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off, scripts: [.init(name: "old", isActive: false)]))
        await h.model.refresh()
        await h.service.enqueueDeletion(.success(.unknown))

        await h.model.deleteScript(named: "old", deactivationAuthorized: false)

        XCTAssertEqual(h.model.operationState, .unknown)
        XCTAssertEqual(h.model.userFacingError,
                       "SievePilot could not verify whether the script was deleted. Refresh to check the server before trying again.")
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
    }

    func testDeleteScriptUsesConfirmedNameEvenIfSelectionChanges() async throws {
        let h = try await harness()
        let scripts = [
            ManageSieveScriptEntry(name: "active", isActive: true),
            ManageSieveScriptEntry(name: "old", isActive: false),
        ]
        await h.service.enqueue(snapshot(.off, scripts: scripts, activeScript: Data("keep;\n".utf8)))
        await h.model.refresh()
        await h.service.setScripts(["old": Data("discard;\n".utf8)])
        await h.model.selectScript("old")
        await h.model.selectScript("active")
        await h.service.enqueueDeletion(.success(.verified(snapshot(.off,
            scripts: [.init(name: "active", isActive: true)], activeScript: Data("keep;\n".utf8)))))

        await h.model.deleteScript(named: "old", deactivationAuthorized: false)

        let deletionNames = await h.service.deletionNames()
        XCTAssertEqual(deletionNames, ["old"])
    }

    func testDeleteRequiresSecondConfirmationWhenFreshServerStateBecameActive() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off, scripts: [.init(name: "target", isActive: false)]))
        await h.model.refresh()
        let activeSnapshot = snapshot(.off, scripts: [.init(name: "target", isActive: true)],
                                      activeScript: Data("keep;\n".utf8))
        await h.service.enqueueDeletion(.success(.activeConfirmationRequired(activeSnapshot)))

        await h.model.deleteScript(named: "target", deactivationAuthorized: false)

        let authorizations = await h.service.deletionAuthorizationValues()
        XCTAssertEqual(authorizations, [false])
        XCTAssertEqual(h.model.selectedScriptEntry, .init(name: "target", isActive: true))
        XCTAssertEqual(h.model.operationState, .verified)
        XCTAssertEqual(h.model.userFacingError,
                       "The script is now active. Review the active-script warning and confirm deletion again.")
    }

    func testDeleteScriptDisablesAnotherDeleteWhileInFlight() async throws {
        let h = try await harness()
        let gate = Gate()
        await h.service.enqueue(snapshot(.off, scripts: [.init(name: "old", isActive: false)]))
        await h.model.refresh()
        await h.service.setDeletionGate(gate)
        await h.service.enqueueDeletion(.success(.verified(snapshot(.off))))

        let first = Task { @MainActor in
            await h.model.deleteScript(named: "old", deactivationAuthorized: false)
        }
        await eventually { await h.service.deletionNames().count == 1 }
        XCTAssertTrue(h.model.isOperationInProgress)
        XCTAssertFalse(h.model.canDeleteSelectedScript)

        let second = Task { @MainActor in
            await h.model.deleteScript(named: "old", deactivationAuthorized: false)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let namesWhileBlocked = await h.service.deletionNames()
        XCTAssertEqual(namesWhileBlocked, ["old"])

        await gate.open()
        await first.value
        await second.value
    }

    func testLifecycleInvalidationDuringVerifiedDeleteLeavesStateStale() async throws {
        let h = try await harness()
        let gate = Gate()
        await h.service.enqueue(snapshot(.off, scripts: [.init(name: "old", isActive: false)]))
        await h.model.refresh()
        await h.service.setDeletionGate(gate)
        await h.service.enqueueDeletion(.success(.verified(snapshot(.off))))

        let deletion = Task { @MainActor in
            await h.model.deleteScript(named: "old", deactivationAuthorized: false)
        }
        await eventually { await h.service.deletionNames().count == 1 }
        await h.model.handle(.networkLost)
        await gate.open()
        await deletion.value

        XCTAssertEqual(h.model.operationState, .stale)
        XCTAssertTrue(h.model.listedScripts.isEmpty)
        XCTAssertNil(h.model.verifiedAt)
    }

    func testDeleteRejectionAfterDeactivationExplainsInactiveState() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off, scripts: [.init(name: "active", isActive: true)],
                                         activeScript: Data("keep;\n".utf8)))
        await h.model.refresh()
        await h.service.enqueueDeletion(.failure(SieveAccountServiceError.scriptDeletionRejected(deactivated: true)))

        await h.model.deleteScript(named: "active", deactivationAuthorized: true)

        XCTAssertEqual(h.model.userFacingError,
                       "The script was deactivated but the server refused to delete it. It remains stored and inactive, and no Sieve script is active. Refresh to verify the server state.")
        XCTAssertEqual(h.model.operationState, .error)
    }

    func testDeactivationRejectionSaysScriptWasNotDeleted() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off, scripts: [.init(name: "active", isActive: true)],
                                         activeScript: Data("keep;\n".utf8)))
        await h.model.refresh()
        await h.service.enqueueDeletion(.failure(SieveAccountServiceError.scriptDeactivationRejected))

        await h.model.deleteScript(named: "active", deactivationAuthorized: true)

        XCTAssertEqual(h.model.userFacingError,
                       "The server refused to deactivate the active script, so it was not deleted. Refresh to verify the server state.")
        XCTAssertEqual(h.model.operationState, .error)
    }

    func testVerifiedOnBecomesExpiryPassedWhenLocalClockPassesExpiry() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.on(configuration: parsed(expiry: 1_800_000_500))))
        await h.model.refresh()
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOn)
        clock.set(Date(timeIntervalSince1970: 1_800_000_501))
        XCTAssertEqual(h.model.outOfOfficeStatus, .expiryPassed)
    }

    func testConflictLabelIsExact() {
        XCTAssertEqual(AppModel.OutOfOfficeStatus.conflict.label, "Conflict — active script changed elsewhere")
    }

    // MARK: Validation

    func testBlankSubjectOmitsSubjectAndConfigurationUsesVerifiedAccountAddress() async throws {
        let h = try await harness()
        fillValid(h.model, subject: "   ")
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed(subject: nil))))))
        await h.model.saveAndActivate()
        let applied = await h.service.appliedConfigurations()
        let configuration = try XCTUnwrap(try XCTUnwrap(applied.first))
        XCTAssertNil(configuration.subject)
        XCTAssertEqual(configuration.message, "Back soon")
        XCTAssertEqual(configuration.emailAddress, "user@example.org")
        XCTAssertEqual(configuration.expiry.timeZoneIdentifier, "Europe/Warsaw")
        XCTAssertEqual(configuration.expiry.utcOffsetSeconds, 3600)
        XCTAssertEqual(configuration.expiry.instant, Date(timeIntervalSince1970: 1_801_497_600)) // 2027-02-01T16:00:00Z
    }

    func testEmptyMessageAndPastExpiryNeverReachTheService() async throws {
        let h = try await harness()
        fillValid(h.model, message: " \n ")
        await h.model.saveAndActivate()
        XCTAssertNotNil(h.model.userFacingError)

        h.model.acknowledgeError()
        fillValid(h.model)
        h.model.expiryLocal = DateComponents(year: 2027, month: 1, day: 15, hour: 8, minute: 0) // 07:00Z, before now
        await h.model.saveAndActivate()
        XCTAssertNotNil(h.model.userFacingError)
        let applied = await h.service.appliedConfigurations()
        XCTAssertTrue(applied.isEmpty)
    }

    func testNonexistentDaylightSavingTimeIsRejected() async throws {
        let h = try await harness()
        fillValid(h.model)
        h.model.expiryLocal = DateComponents(year: 2027, month: 3, day: 28, hour: 2, minute: 30)
        XCTAssertEqual(h.model.expiryStatus, .nonexistentLocalTime)
        await h.model.saveAndActivate()
        XCTAssertNotNil(h.model.userFacingError)
        let applied = await h.service.appliedConfigurations()
        XCTAssertTrue(applied.isEmpty)
    }

    func testRepeatedLocalTimeRequiresConfirmedOffsetAndPersistsIt() async throws {
        let h = try await harness()
        fillValid(h.model)
        h.model.expiryLocal = DateComponents(year: 2027, month: 10, day: 31, hour: 2, minute: 30)
        XCTAssertEqual(h.model.repeatedTimeOffsetOptions, [7200, 3600])
        XCTAssertEqual(h.model.expiryStatus, .repeatedLocalTimeNeedsConfirmation(offsets: [7200, 3600]))
        await h.model.saveAndActivate()
        XCTAssertNotNil(h.model.userFacingError)
        var applied = await h.service.appliedConfigurations()
        XCTAssertTrue(applied.isEmpty)

        h.model.acknowledgeError()
        h.model.repeatedTimeOffset = 3600
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed())))))
        await h.model.saveAndActivate()
        applied = await h.service.appliedConfigurations()
        let configuration = try XCTUnwrap(try XCTUnwrap(applied.first))
        XCTAssertEqual(configuration.expiry.utcOffsetSeconds, 3600)
        XCTAssertEqual(configuration.expiry.instant, Date(timeIntervalSince1970: 1_824_946_200)) // 2027-10-31T01:30:00Z
    }

    func testChangingExpiryOrTimeZoneClearsRepeatedTimeConfirmation() async throws {
        let h = try await harness()
        h.model.expiryLocal = DateComponents(year: 2027, month: 10, day: 31, hour: 2, minute: 30)
        h.model.repeatedTimeOffset = 7200
        h.model.expiryLocal = DateComponents(year: 2027, month: 10, day: 31, hour: 2, minute: 45)
        XCTAssertNil(h.model.repeatedTimeOffset)
        h.model.repeatedTimeOffset = 7200
        h.model.expiryTimeZoneIdentifier = "Europe/London"
        XCTAssertNil(h.model.repeatedTimeOffset)
    }

    // MARK: Capabilities

    func testMissingCapabilitiesAreExplicitAndBlockMutation() async throws {
        for (sieve, missing, available) in [
            ("date relational", ["vacation"], false),
            ("vacation relational", ["date"], false),
            ("vacation date", ["relational"], false),
            ("vacation date relational", [String](), true)
        ] {
            let h = try await harness()
            await h.service.enqueue(snapshot(.off, sieve: sieve))
            await h.model.refresh()
            XCTAssertEqual(h.model.missingCapabilities, missing, sieve)
            XCTAssertEqual(h.model.isOutOfOfficeAvailable, available, sieve)
            XCTAssertEqual(h.model.capabilityLimitations.isEmpty, available, sieve)
            for name in missing { XCTAssertTrue(h.model.capabilityLimitations.joined().contains(name), sieve) }
            XCTAssertEqual(h.model.canSaveAndActivate, available, sieve)
            if !available {
                fillValid(h.model)
                await h.model.saveAndActivate()
                await h.model.disable()
                let applied = await h.service.appliedConfigurations()
                XCTAssertTrue(applied.isEmpty, sieve)
            }
        }
    }

    func testScheduledExpiryLimitationNamesDateAndRelationalAndNoLocalFallback() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off, sieve: "vacation"))
        await h.model.refresh()
        XCTAssertEqual(h.model.missingCapabilities, ["date", "relational"])
        let text = h.model.capabilityLimitations.joined(separator: " ")
        XCTAssertTrue(text.contains("Scheduled expiry"))
        XCTAssertTrue(text.contains("date"))
        XCTAssertTrue(text.contains("relational"))
        XCTAssertTrue(text.contains("no local fallback"))
        XCTAssertFalse(text.contains("Out of office is unavailable"))
    }

    /// Production path: the core fails closed with the missing set instead of returning a snapshot.
    func testProductionUnsupportedErrorOnRefreshNamesMissingVacationVersusScheduling() async throws {
        let vacation = try await harness()
        await vacation.service.setError(SieveAccountServiceError.unsupportedCapabilities(missing: ["vacation"]))
        await vacation.model.refresh()
        XCTAssertEqual(vacation.model.operationState, .error)
        XCTAssertNil(vacation.model.verifiedSnapshot)
        XCTAssertEqual(vacation.model.missingCapabilities, ["vacation"])
        XCTAssertFalse(vacation.model.isOutOfOfficeAvailable)
        XCTAssertFalse(vacation.model.canSaveAndActivate)
        var text = vacation.model.capabilityLimitations.joined(separator: " ")
        XCTAssertTrue(text.contains("Out of office is unavailable"))
        XCTAssertTrue(text.contains("vacation"))
        XCTAssertFalse(text.contains("Scheduled expiry"))
        XCTAssertTrue(try XCTUnwrap(vacation.model.userFacingError).contains("vacation"))

        let scheduling = try await harness()
        await scheduling.service.setError(SieveAccountServiceError.unsupportedCapabilities(missing: ["date", "relational"]))
        await scheduling.model.refresh()
        XCTAssertEqual(scheduling.model.missingCapabilities, ["date", "relational"])
        XCTAssertFalse(scheduling.model.isOutOfOfficeAvailable)
        text = scheduling.model.capabilityLimitations.joined(separator: " ")
        XCTAssertTrue(text.contains("Scheduled expiry is unavailable"))
        XCTAssertTrue(text.contains("date, relational"))
        XCTAssertTrue(text.contains("no local fallback"))
        XCTAssertFalse(text.contains("Out of office is unavailable"))
        let message = try XCTUnwrap(scheduling.model.userFacingError)
        XCTAssertTrue(message.contains("date") && message.contains("relational"))
        XCTAssertFalse(message.contains("vacation"))
    }

    func testProductionUnsupportedErrorOnApplyNamesMissingExtensionsAndNeverReportsSuccess() async throws {
        let h = try await harness()
        fillValid(h.model)
        await h.service.enqueueOutcome(.failure(SieveAccountServiceError.unsupportedCapabilities(missing: ["date"])))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.operationState, .error)
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
        XCTAssertEqual(h.model.missingCapabilities, ["date"])
        XCTAssertFalse(h.model.isOutOfOfficeAvailable)
        XCTAssertTrue(h.model.capabilityLimitations.joined(separator: " ").contains("Scheduled expiry"))
        await h.model.disable()
        let applied = await h.service.appliedConfigurations()
        XCTAssertEqual(applied.count, 1, "controls stay blocked after the server reports missing extensions")
    }

    func testReportedMissingCapabilitiesClearOnVerifiedSnapshot() async throws {
        let h = try await harness()
        await h.service.setError(SieveAccountServiceError.unsupportedCapabilities(missing: ["vacation"]))
        await h.model.refresh()
        XCTAssertFalse(h.model.isOutOfOfficeAvailable)
        await h.service.setError(nil)
        await h.service.enqueue(snapshot(.off))
        await h.model.refresh()
        XCTAssertTrue(h.model.isOutOfOfficeAvailable)
        XCTAssertTrue(h.model.missingCapabilities.isEmpty)
    }

    // MARK: Mutations never infer success

    func testSaveAndActivateShowsVerifiedOnOnlyFromTheVerifiedOutcome() async throws {
        let h = try await harness()
        fillValid(h.model)
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed()), at: 1_800_000_050))))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.operationState, .verified)
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOn)
        XCTAssertEqual(h.model.verifiedAt, Date(timeIntervalSince1970: 1_800_000_050))
        XCTAssertNil(h.model.userFacingError)
        let refreshCalls = await h.service.refreshCalls()
        XCTAssertEqual(refreshCalls, 0, "mutation uses its own single verified connection")
    }

    func testVerifiedOutcomeThatIsOffIsNotReportedAsOn() async throws {
        let h = try await harness()
        fillValid(h.model)
        await h.service.enqueueOutcome(.success(.verified(snapshot(.off))))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOff)
    }

    func testUnknownActivationStaysUnknownWithPersistentError() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off))
        await h.model.refresh()
        fillValid(h.model)
        await h.service.enqueueOutcome(.success(.unknown))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.operationState, .unknown)
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
        XCTAssertNil(h.model.verifiedAt)
        XCTAssertNotNil(h.model.userFacingError)
    }

    func testConflictShowsConflictAndPersistsUntilAcknowledgedOrResolved() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.on(configuration: parsed())))
        await h.model.refresh()
        fillValid(h.model)
        await h.service.enqueueOutcome(.success(.conflict))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.outOfOfficeStatus, .conflict)
        XCTAssertTrue(h.model.hasUnresolvedConflict)
        XCTAssertNotNil(h.model.userFacingError)

        // A refresh that is still running neither hides the conflict nor the message.
        let gate = Gate()
        await h.service.setGate(gate)
        await h.service.enqueue(snapshot(.off, at: 1_800_000_090))
        let refresh = Task { await h.model.refresh() }
        await eventually { h.model.operationState == .refreshing }
        XCTAssertNotNil(h.model.userFacingError)
        XCTAssertEqual(h.model.outOfOfficeStatus, .conflict)
        await gate.open()
        await refresh.value
        XCTAssertNil(h.model.userFacingError)
        XCTAssertFalse(h.model.hasUnresolvedConflict)
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOff)
    }

    func testAcknowledgingAConflictClearsMessageButNeverClaimsVerified() async throws {
        let h = try await harness()
        fillValid(h.model)
        await h.service.enqueueOutcome(.success(.conflict))
        await h.model.saveAndActivate()
        h.model.acknowledgeError()
        XCTAssertNil(h.model.userFacingError)
        XCTAssertFalse(h.model.hasUnresolvedConflict)
        XCTAssertEqual(h.model.operationState, .stale)
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
    }

    func testServiceErrorsAreRedactedPersistentAndLeaveStatusUnknown() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off))
        await h.model.refresh()
        fillValid(h.model)
        await h.service.enqueueOutcome(.failure(NSError(domain: "secret-sasl-payload", code: 9)))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.operationState, .error)
        let message = try XCTUnwrap(h.model.userFacingError)
        XCTAssertFalse(message.contains("secret-sasl-payload"))
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
        h.model.markStale()
        XCTAssertEqual(h.model.userFacingError, message, "stale marking must not clear errors")
        h.model.acknowledgeError()
        XCTAssertNil(h.model.userFacingError)
    }

    func testValidationQuotaAndActivationRejectionsStayDistinctAndNeverReportSuccess() async throws {
        let fallback = "Unable to apply the out-of-office change. Refresh to verify the server state."
        let cases: [(SieveAccountServiceError, AppModel.FailureCategory)] = [
            (.scriptRejected, .validation), (.quotaExceeded, .quota), (.activationRejected, .activation),
            (.manifest, .localRecord)
        ]
        var messages: Set<String> = []
        for (error, category) in cases {
            let h = try await harness()
            await h.service.enqueue(snapshot(.off))
            await h.model.refresh()
            fillValid(h.model)
            await h.service.enqueueOutcome(.failure(error))
            await h.model.saveAndActivate()
            XCTAssertEqual(h.model.operationState, .error, "\(error)")
            XCTAssertEqual(h.model.outOfOfficeStatus, .unknown, "\(error)")
            XCTAssertNil(h.model.verifiedAt, "\(error)")
            let message = try XCTUnwrap(h.model.userFacingError, "\(error)")
            XCTAssertEqual(message, category.message, "\(error)")
            XCTAssertNotEqual(message, fallback, "\(error)")
            XCTAssertFalse(message.contains("Back soon"), "Script content must not appear in errors")
            messages.insert(message)

            // Disabling goes through the same mapping.
            h.model.acknowledgeError()
            await h.service.enqueueOutcome(.failure(error))
            await h.model.disable()
            XCTAssertEqual(h.model.userFacingError, category.message, "\(error)")
        }
        XCTAssertEqual(messages.count, cases.count)

        // The conflict and unverified outcomes keep their own wording, separate from every rejection above.
        let h = try await harness()
        fillValid(h.model)
        await h.service.enqueueOutcome(.success(.conflict))
        await h.model.saveAndActivate()
        let conflict = try XCTUnwrap(h.model.userFacingError)
        h.model.acknowledgeError()
        await h.service.enqueueOutcome(.success(.unknown))
        await h.model.saveAndActivate()
        let unverified = try XCTUnwrap(h.model.userFacingError)
        XCTAssertNotEqual(conflict, unverified)
        XCTAssertFalse(messages.contains(conflict))
        XCTAssertFalse(messages.contains(unverified))
        // An authentication failure while applying is reported as such, not as an apply failure.
        h.model.acknowledgeError()
        await h.service.enqueueOutcome(.failure(ManageSieveSessionFactoryError.authenticationRejected))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.userFacingError, AppModel.FailureCategory.authenticationRejected.message)
    }

    func testCancellationDuringActivationIsUnknown() async throws {
        let h = try await harness()
        fillValid(h.model)
        await h.service.enqueueOutcome(.failure(CancellationError()))
        await h.model.saveAndActivate()
        XCTAssertEqual(h.model.operationState, .unknown)
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
    }

    func testDisableCallsServiceWithNilConfigurationAndMapsOutcomes() async throws {
        let h = try await harness()
        await h.service.enqueueOutcome(.success(.verified(snapshot(.off))))
        await h.model.disable()
        var applied = await h.service.appliedConfigurations()
        XCTAssertEqual(applied.count, 1)
        XCTAssertNil(applied[0])
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOff)

        await h.service.enqueueOutcome(.success(.unknown))
        await h.model.disable()
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
        await h.service.enqueueOutcome(.success(.conflict))
        await h.model.disable()
        XCTAssertEqual(h.model.outOfOfficeStatus, .conflict)
        applied = await h.service.appliedConfigurations()
        XCTAssertEqual(applied.count, 3)
    }

    func testFirstActivationRequiresRuleOrderAcknowledgement() async throws {
        let store = InMemoryActivationAcknowledgementStore()
        let h = try await harness(acknowledged: false, store: store)
        fillValid(h.model)
        XCTAssertFalse(h.model.ruleOrderingAcknowledged)
        XCTAssertFalse(h.model.canSaveAndActivate)
        await h.model.saveAndActivate()
        XCTAssertNotNil(h.model.userFacingError)
        var applied = await h.service.appliedConfigurations()
        XCTAssertTrue(applied.isEmpty)

        h.model.acknowledgeRuleOrdering()
        XCTAssertTrue(h.model.ruleOrderingAcknowledged)
        h.model.acknowledgeError()
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed())))))
        await h.model.saveAndActivate()
        applied = await h.service.appliedConfigurations()
        XCTAssertEqual(applied.count, 1)

        // The acknowledgement is remembered per account across model instances.
        let second = try await harness(acknowledged: false, store: store)
        XCTAssertTrue(second.model.ruleOrderingAcknowledged)
    }

    func testControlsAreDisabledWhileOperationsRun() async throws {
        let h = try await harness()
        fillValid(h.model)
        XCTAssertTrue(h.model.canSaveAndActivate)
        XCTAssertFalse(h.model.isOperationInProgress)
        let gate = Gate()
        await h.service.setApplyGate(gate)
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed())))))
        let save = Task { await h.model.saveAndActivate() }
        await eventually { h.model.operationState == .applying }
        XCTAssertTrue(h.model.isOperationInProgress)
        XCTAssertFalse(h.model.canSaveAndActivate)
        XCTAssertFalse(h.model.canDisable)
        await h.model.saveAndActivate() // re-entrancy is ignored
        await gate.open()
        await save.value
        let applied = await h.service.appliedConfigurations()
        XCTAssertEqual(applied.count, 1)
        XCTAssertFalse(h.model.isOperationInProgress)
    }

    func testVerifiedStatePopulatesPristineFormButKeepsUserEdits() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.on(configuration: parsed(subject: "Server subject", message: "Server message", expiry: 1_801_497_600))))
        await h.model.refresh()
        XCTAssertEqual(h.model.subject, "Server subject")
        XCTAssertEqual(h.model.message, "Server message")
        XCTAssertEqual(h.model.expiryLocal.hour, 17) // 16:00Z in Warsaw (CET)

        h.model.message = "My edit"
        await h.service.enqueue(snapshot(.on(configuration: parsed(message: "Newer server message"))))
        await h.model.refresh()
        XCTAssertEqual(h.model.message, "My edit")
    }

    // MARK: Refresh coordination

    func testPopoverOpenWakeAndActivationShareOneInFlightRefresh() async throws {
        let h = try await harness()
        let gate = Gate()
        await h.service.setGate(gate)
        await h.service.enqueue(snapshot(.off))
        async let a: Void = h.model.popoverDidOpen()
        async let b: Void = h.model.requestRefresh()
        async let c: Void = h.model.handle(.didBecomeActive)
        await eventually { await h.service.refreshCalls() >= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.open()
        _ = await (a, b, c)
        let calls = await h.service.refreshCalls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(h.model.operationState, .verified)
    }

    func testWakeAndReconnectMarkStaleImmediatelyAndCoalesceToOneRefresh() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off))
        await h.service.enqueue(snapshot(.off, at: 1_800_000_099))
        await h.model.refresh()
        XCTAssertEqual(h.model.operationState, .verified)

        h.lifecycle.send(.didWake)
        XCTAssertEqual(h.model.operationState, .stale, "wake must mark stale synchronously")
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
        h.lifecycle.send(.networkReconnected)
        XCTAssertEqual(h.model.operationState, .stale)
        await h.model.settleScheduledRefresh()
        let calls = await h.service.refreshCalls()
        XCTAssertEqual(calls, 2) // the initial refresh plus exactly one coalesced refresh
        XCTAssertEqual(h.model.operationState, .verified)
        XCTAssertEqual(h.model.verifiedAt, Date(timeIntervalSince1970: 1_800_000_099))
    }

    func testNetworkLossMarksStaleWithoutRefreshing() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off))
        await h.model.refresh()
        h.lifecycle.send(.networkLost)
        XCTAssertEqual(h.model.operationState, .stale)
        await h.model.settleScheduledRefresh()
        let calls = await h.service.refreshCalls()
        XCTAssertEqual(calls, 1)
    }

    func testWakeSupersedesInFlightRefreshAndStaleCompletionIsSuppressed() async throws {
        let h = try await harness()
        let gate = Gate()
        await h.service.setGate(gate)
        await h.service.enqueue(snapshot(.on(configuration: parsed()), at: 1_800_000_001)) // pre-sleep data
        await h.service.enqueue(snapshot(.off, at: 1_800_000_002))
        let first = Task { await h.model.refresh() }
        await eventually { await h.service.refreshCalls() == 1 }
        h.lifecycle.send(.didWake)
        XCTAssertEqual(h.model.operationState, .stale)
        await eventually { await h.service.refreshCalls() == 2 }
        await gate.open()
        await first.value
        await h.model.settleScheduledRefresh()
        XCTAssertEqual(h.model.verifiedAt, Date(timeIntervalSince1970: 1_800_000_002))
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOff)
    }

    func testWakeDuringMutationLeavesResultStaleUntilRefreshVerifies() async throws {
        let h = try await harness(delay: .seconds(60))
        fillValid(h.model)
        let gate = Gate()
        await h.service.setApplyGate(gate)
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed())))))
        let save = Task { await h.model.saveAndActivate() }
        await eventually { h.model.operationState == .applying }
        h.lifecycle.send(.didWake)
        await gate.open()
        await save.value
        XCTAssertEqual(h.model.operationState, .stale)
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)

        await h.service.enqueue(snapshot(.on(configuration: parsed()), at: 1_800_000_200))
        await h.model.requestRefresh()
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOn)
        XCTAssertEqual(h.model.verifiedAt, Date(timeIntervalSince1970: 1_800_000_200))
    }

    func testResignActiveDuringMutationDoesNotDowngradeItsVerifiedOutcome() async throws {
        let h = try await harness(delay: .seconds(60))
        fillValid(h.model)
        let gate = Gate()
        await h.service.setApplyGate(gate)
        await h.service.enqueueOutcome(.success(.verified(snapshot(.on(configuration: parsed())))))
        let save = Task { await h.model.saveAndActivate() }
        await eventually { h.model.operationState == .applying }
        h.lifecycle.send(.didResignActive)
        await gate.open()
        await save.value
        XCTAssertEqual(h.model.operationState, .verified)
        XCTAssertEqual(h.model.outOfOfficeStatus, .verifiedOn)
    }

    func testPopoverOpenDuringSaveWaitsForItThenRefreshesOnce() async throws {
        let persistence = AppPersistence(), gate = Gate()
        let h = try await harness(persistence: persistence)
        await persistence.setGate(gate)
        await h.service.enqueue(snapshot(.off))
        h.model.emailAddress = "user@example.org"; h.model.username = "user"; h.model.password = "secret"
        let save = Task { await h.model.testAndSave() }
        await eventually { await persistence.startedCount() == 1 }
        let open = Task { await h.model.popoverDidOpen() }
        try await Task.sleep(nanoseconds: 20_000_000)
        var calls = await h.service.refreshCalls()
        XCTAssertEqual(calls, 0)
        await gate.open()
        await save.value
        await open.value
        calls = await h.service.refreshCalls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(h.model.operationState, .verified)
    }

    func testLoadAndRefreshVerifiesAfterLaunchAndManualRefreshStillWorks() async throws {
        let h = try await harness()
        await h.service.enqueue(snapshot(.off))
        await h.model.loadAndRefresh()
        XCTAssertEqual(h.model.operationState, .verified)
        await h.service.setError(NSError(domain: "x", code: 1))
        await h.model.refresh()
        XCTAssertEqual(h.model.operationState, .error)
        XCTAssertEqual(h.model.outOfOfficeStatus, .unknown)
        await h.service.setError(nil)
        await h.service.enqueue(snapshot(.off))
        await h.model.refresh()
        XCTAssertEqual(h.model.operationState, .verified)
    }

    // MARK: Settings navigation

    func testSettingsNavigationReturnsAfterSaveAndDelete() async throws {
        let sessions = AppSessionProvider()
        let h = try await harness(sessions: sessions)
        h.model.showSettings()
        XCTAssertTrue(h.model.isShowingSettings)
        h.model.closeSettings()
        XCTAssertFalse(h.model.isShowingSettings)

        h.model.showSettings()
        h.model.password = "secret"
        await h.model.testAndSave()
        XCTAssertFalse(h.model.isShowingSettings)

        h.model.showSettings()
        await h.model.deleteAccount()
        XCTAssertFalse(h.model.isShowingSettings)
        XCTAssertNil(h.model.persistedAccount)
    }

    // MARK: Lifecycle coordinator

    func testCoordinatorEmitsWakeFromWorkspaceNotificationCenter() async throws {
        let workspaceCenter = NotificationCenter(), appCenter = NotificationCenter()
        let monitor = FakePathMonitor()
        let coordinator = AppLifecycleCoordinator(notificationCenter: appCenter, workspaceNotificationCenter: workspaceCenter,
                                                  pathMonitor: monitor)
        var events: [AppLifecycleEvent] = []
        coordinator.start { events.append($0) }
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        await eventually { events.count == 3 }
        XCTAssertEqual(Set(events), [.didWake, .didBecomeActive, .didResignActive])
    }

    func testCoordinatorMapsPathTransitionsAfterBaseline() async throws {
        let monitor = FakePathMonitor()
        let coordinator = AppLifecycleCoordinator(notificationCenter: NotificationCenter(),
                                                  workspaceNotificationCenter: NotificationCenter(), pathMonitor: monitor)
        var events: [AppLifecycleEvent] = []
        coordinator.start { events.append($0) }
        monitor.send(.init(isSatisfied: true, signature: "en0"))      // baseline
        XCTAssertTrue(events.isEmpty)
        monitor.send(.init(isSatisfied: true, signature: "en0"))      // unchanged
        XCTAssertTrue(events.isEmpty)
        monitor.send(.init(isSatisfied: false, signature: ""))
        monitor.send(.init(isSatisfied: false, signature: ""))        // repeated loss
        monitor.send(.init(isSatisfied: true, signature: "en0"))
        monitor.send(.init(isSatisfied: true, signature: "en1"))      // interface change
        XCTAssertEqual(events, [.networkLost, .networkReconnected, .networkReconnected])
    }

    func testCoordinatorRestartStopsThePreviousMonitorRegistration() async throws {
        let monitor = FakePathMonitor()
        let coordinator = AppLifecycleCoordinator(notificationCenter: NotificationCenter(),
                                                  workspaceNotificationCenter: NotificationCenter(), pathMonitor: monitor)
        coordinator.start { _ in }
        coordinator.start { _ in }
        XCTAssertGreaterThanOrEqual(monitor.stopCount, 1)
    }
}
