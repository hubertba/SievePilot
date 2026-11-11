import Combine
import Foundation
import SievePilotCore

@MainActor
final class AppModel: ObservableObject {
    static let productName = "SievePilot"

    enum OperationState: Equatable {
        case idle, loading, testing, refreshing, applying, stale, verified, unknown, error
    }

    /// Operational out-of-office status. It is derived only from a verified server snapshot (or from a
    /// reported conflict) and is never inferred from the last requested operation.
    enum OutOfOfficeStatus: Equatable, Sendable {
        case verifiedOn, verifiedOff, expiryPassed, unknown, conflict

        var label: String {
            switch self {
            case .verifiedOn: "Verified On"
            case .verifiedOff: "Verified Off"
            case .expiryPassed: "Expiry passed — script verified; server clock applies"
            case .unknown: "Unknown — verification required"
            case .conflict: "Conflict — active script changed elsewhere"
            }
        }
    }

    enum ExpiryStatus: Equatable, Sendable {
        case valid(ResolvedExpiry)
        case inPast(ResolvedExpiry)
        case nonexistentLocalTime
        case repeatedLocalTimeNeedsConfirmation(offsets: [Int])
        case invalidLocalTime
    }

    @Published var emailAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published var usesAutomaticDiscovery = true
    @Published var manualHost = ""
    @Published var manualPort = "4190"
    @Published private(set) var discoveryPreview: String?
    @Published private(set) var persistedAccount: AccountConfiguration? {
        didSet {
            ruleOrderingAcknowledged = persistedAccount.map { acknowledgements.hasAcknowledged($0.accountID) } ?? false
        }
    }
    @Published private(set) var operationState: OperationState = .idle
    @Published private(set) var verifiedSnapshot: VerifiedAccountSnapshot?
    @Published var userFacingError: String?
    @Published private(set) var hasUnresolvedConflict = false
    @Published private(set) var ruleOrderingAcknowledged = false
    /// Extensions the server reported missing when the core failed closed before returning a snapshot.
    @Published private(set) var reportedMissingCapabilities: [String] = []
    @Published var isShowingSettings = false

    // Out-of-office form. Expiry is a wall-clock time in a named zone; it is resolved to an instant on save.
    @Published var subject = "" { didSet { formDidChange() } }
    @Published var message = "" { didSet { formDidChange() } }
    @Published var expiryLocal = DateComponents() { didSet { expiryDidChange() } }
    @Published var expiryTimeZoneIdentifier = "" { didSet { expiryDidChange() } }
    /// The UTC offset the user confirmed for a repeated local time; reset whenever the expiry changes.
    @Published var repeatedTimeOffset: Int?

    private enum Operation {
        case load, testAndSave, refresh, delete, apply

        var state: OperationState {
            switch self {
            case .load, .delete: return .loading
            case .testAndSave: return .testing
            case .refresh: return .refreshing
            case .apply: return .applying
            }
        }

        /// Operations that read or mutate persisted state; resign-active must not invalidate them.
        var isCritical: Bool { self != .refresh }
    }

    private enum SetupFormError: Error { case missingPassword }

    private let settingsStore: any AccountConfigurationStoring
    private let persistence: any AccountPersistenceCoordinating
    private let discovery: any SieveServiceDiscovering
    private let sessionProvider: any ManageSieveCandidateSessionProviding
    private let accountService: any SieveAccountServicing
    private let lifecycle: (any AppLifecycleObserving)?
    private let acknowledgements: any ActivationAcknowledgementStoring
    private let refreshCoalescingDelay: Duration
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let timeZone: TimeZone
    private var generation = 0
    private var operationTask: Task<Void, Never>?
    private var activeOperation: Operation?
    private var commitTask: Task<Void, Error>?
    private var scheduledRefresh: Task<Void, Never>?
    private var invalidatedDuringCritical = false
    private var isPopulatingForm = false
    private var formIsDirty = false

    private static let requiredExtensions = ["vacation", "date", "relational"]

    init(settingsStore: any AccountConfigurationStoring,
         persistence: any AccountPersistenceCoordinating,
         discovery: any SieveServiceDiscovering,
         sessionProvider: any ManageSieveCandidateSessionProviding,
         accountService: any SieveAccountServicing,
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current,
         timeZone: TimeZone = .current,
         lifecycle: (any AppLifecycleObserving)? = nil,
         acknowledgements: any ActivationAcknowledgementStoring = InMemoryActivationAcknowledgementStore(),
         refreshCoalescingDelay: Duration = .milliseconds(750)) {
        self.settingsStore = settingsStore
        self.persistence = persistence
        self.discovery = discovery
        self.sessionProvider = sessionProvider
        self.accountService = accountService
        self.now = now
        self.calendar = calendar
        self.timeZone = timeZone
        self.lifecycle = lifecycle
        self.acknowledgements = acknowledgements
        self.refreshCoalescingDelay = refreshCoalescingDelay
        resetExpiryToDefault()
        lifecycle?.start { [weak self] event in
            guard let self else { return }
            // Staleness is applied synchronously; refreshes are scheduled and coalesced.
            self.applyStaleness(for: event)
            switch event {
            case .didBecomeActive: Task { await self.requestRefresh() }
            case .didWake, .networkReconnected: self.scheduleCoalescedRefresh()
            case .didResignActive, .networkLost: break
            }
        }
    }

    convenience init(dependencies: AppDependencies) {
        self.init(settingsStore: dependencies.settingsStore, persistence: dependencies.persistence,
                  discovery: dependencies.discovery, sessionProvider: dependencies.sessionProvider,
                  accountService: dependencies.accountService, lifecycle: dependencies.lifecycle,
                  acknowledgements: dependencies.acknowledgements)
    }

    /// Launch entry point: load the saved account, then verify the server state once.
    func loadAndRefresh() async {
        await load()
        await requestRefresh()
    }

    func load() async {
        await run(.load) { [self] token in
            do {
                let account = try await settingsStore.load()
                guard isCurrent(token) else { return }
                persistedAccount = account
                verifiedSnapshot = nil
                reportedMissingCapabilities = []
                if let account { populateForm(from: account); operationState = .stale }
                else { operationState = .idle }
            } catch is CancellationError {
                finishCancellation(token)
            } catch {
                finishFailure(token, message: "Unable to load the saved account.")
            }
        }
    }

    func testAndSave() async {
        await run(.testAndSave) { [self] token in
            do {
                let configuration = try configurationFromForm()
                guard !password.isEmpty else { throw SetupFormError.missingPassword }
                let candidate = Data(password.utf8)
                if usesAutomaticDiscovery {
                    let endpoint = try await discovery.discover(emailAddress: configuration.emailAddress)
                    guard isCurrent(token) else { return }
                    discoveryPreview = "\(endpoint.host):\(endpoint.port)"
                } else {
                    discoveryPreview = nil
                }
                // Authenticate with the candidate form password; nothing is persisted until this succeeds.
                _ = try await sessionProvider.withAuthenticatedSession(account: configuration,
                                                                       password: candidate) { _ in true }
                guard isCurrent(token) else { return }
                guard !Task.isCancelled else { throw CancellationError() }
                let persistence = persistence
                try await commit { try await persistence.save(configuration: configuration, password: candidate) }
                // The mutation is durable: reflect it even if a newer operation superseded this one.
                persistedAccount = configuration
                verifiedSnapshot = nil
                hasUnresolvedConflict = false
                reportedMissingCapabilities = []
                if isCurrent(token) {
                    password = ""
                    userFacingError = nil
                    operationState = .stale
                    isShowingSettings = false
                }
            } catch is CancellationError {
                finishCancellation(token)
            } catch is AccountConfigurationError {
                finishFailure(token, message: "Enter a valid email address, username, and server configuration.")
            } catch SetupFormError.missingPassword {
                finishFailure(token, message: "Enter your password.")
            } catch {
                finishFailure(token, message: "Unable to verify and save this account.")
            }
        }
    }

    func refresh() async {
        guard let account = persistedAccount else { return }
        guard activeOperation?.isCritical != true else { return }
        await run(.refresh) { [self] token in
            do {
                let snapshot = try await accountService.refresh(account: account)
                guard isCurrent(token) else { return }
                adopt(snapshot)
                userFacingError = nil
                operationState = .verified
            } catch is CancellationError {
                finishCancellation(token)
            } catch {
                finishFailure(token, error: error, fallback: "Unable to verify the server state.")
            }
        }
    }

    func deleteAccount() async {
        guard let account = persistedAccount else { return }
        await run(.delete) { [self] token in
            do {
                let persistence = persistence
                try await commit { try await persistence.delete(accountID: account.accountID) }
                persistedAccount = nil
                verifiedSnapshot = nil
                discoveryPreview = nil
                hasUnresolvedConflict = false
                reportedMissingCapabilities = []
                isShowingSettings = false
                if isCurrent(token) {
                    password = ""
                    userFacingError = nil
                    operationState = .idle
                }
            } catch is CancellationError {
                finishCancellation(token)
            } catch {
                finishFailure(token, message: "Unable to delete this account.")
            }
        }
    }

    func handle(_ event: AppLifecycleEvent) async {
        applyStaleness(for: event)
        switch event {
        case .didBecomeActive: await requestRefresh()
        case .didWake, .networkReconnected: await scheduleCoalescedRefresh().value
        case .didResignActive, .networkLost: break
        }
    }

    /// Invalidates only a verification in flight. Loads and persistence mutations are never dropped here;
    /// a mutation that is interrupted by a wake or network change finishes as stale rather than verified.
    func markStale() { markStale(invalidatingCriticalOperation: false) }

    /// `invalidatingCriticalOperation` is for wake and network changes: the in-flight mutation cannot be
    /// cancelled, so its outcome is recorded but shown as stale until a later refresh verifies it.
    private func markStale(invalidatingCriticalOperation: Bool) {
        guard activeOperation?.isCritical != true else {
            if invalidatingCriticalOperation { invalidatedDuringCritical = true }
            return
        }
        operationTask?.cancel()
        operationTask = nil
        activeOperation = nil
        generation += 1
        if persistedAccount != nil { operationState = .stale }
    }

    /// Refreshes now, sharing any refresh already in flight. Waits for a running save/delete/apply first.
    func requestRefresh() async {
        guard persistedAccount != nil else { return }
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        var waits = 0
        while activeOperation?.isCritical == true, let task = operationTask, waits < 8 {
            await task.value
            waits += 1
        }
        guard persistedAccount != nil else { return }
        if activeOperation == .refresh, let task = operationTask {
            await task.value
            return
        }
        await refresh()
    }

    func popoverDidOpen() async { await requestRefresh() }

    /// Debounces wake and reconnect bursts into one refresh. Returns the pending task so callers can await it.
    @discardableResult
    func scheduleCoalescedRefresh() -> Task<Void, Never> {
        if let existing = scheduledRefresh { return existing }
        let delay = refreshCoalescingDelay
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.scheduledRefresh = nil
            await self.requestRefresh()
        }
        scheduledRefresh = task
        return task
    }

    /// Test hook: waits for a scheduled lifecycle refresh (and the refresh it starts) to finish.
    func settleScheduledRefresh() async { await scheduledRefresh?.value }

    /// Acknowledges a persistent error or conflict. This never claims the server state is verified.
    func acknowledgeError() {
        userFacingError = nil
        hasUnresolvedConflict = false
        if operationState == .error { operationState = persistedAccount == nil ? .idle : .stale }
    }

    func dismissError() { acknowledgeError() }

    func acknowledgeRuleOrdering() {
        guard let account = persistedAccount else { return }
        acknowledgements.acknowledge(account.accountID)
        ruleOrderingAcknowledged = true
    }

    func showSettings() { isShowingSettings = true }
    func closeSettings() { isShowingSettings = false }

    // MARK: Out-of-office mutations

    func saveAndActivate() async {
        guard let account = persistedAccount, activeOperation == nil else { return }
        guard isOutOfOfficeAvailable else {
            userFacingError = "Out of office is unavailable on this server. See the listed server limitations."
            return
        }
        guard ruleOrderingAcknowledged else {
            userFacingError = "Read and acknowledge the rule-order notice before the first activation."
            return
        }
        let configuration: OutOfOfficeConfiguration
        do { configuration = try outOfOfficeConfigurationFromForm(account: account) }
        catch let error as OutOfOfficeInputError { userFacingError = error.message; return }
        catch { userFacingError = "Check the out-of-office message and expiry."; return }
        await apply(configuration, account: account)
    }

    func disable() async {
        guard let account = persistedAccount, activeOperation == nil else { return }
        guard isOutOfOfficeAvailable else {
            userFacingError = "Out of office is unavailable on this server. See the listed server limitations."
            return
        }
        await apply(nil, account: account)
    }

    private func apply(_ configuration: OutOfOfficeConfiguration?, account: AccountConfiguration) async {
        await run(.apply) { [self] token in
            do {
                let outcome = try await accountService.applyOutOfOffice(account: account, configuration: configuration)
                guard isCurrent(token) else { return }
                switch outcome {
                case .verified(let snapshot):
                    formIsDirty = false
                    adopt(snapshot)
                    userFacingError = nil
                    operationState = invalidatedDuringCritical ? .stale : .verified
                case .conflict:
                    hasUnresolvedConflict = true
                    userFacingError = "The active script changed elsewhere, so nothing was activated. Refresh to review the current server state, then try again."
                    operationState = .stale
                case .unknown:
                    userFacingError = "SievePilot could not verify whether the change took effect. Refresh to check the server before trying again."
                    operationState = .unknown
                }
            } catch is CancellationError {
                finishCancellation(token)
            } catch {
                finishFailure(token, error: error, fallback: "Unable to apply the out-of-office change. Refresh to verify the server state.")
            }
        }
    }

    // MARK: Derived presentation state

    var outOfOfficeStatus: OutOfOfficeStatus {
        if operationState == .verified, let snapshot = verifiedSnapshot {
            switch snapshot.outOfOfficeState {
            case .off: return .verifiedOff
            case .on(let configuration):
                return now() < configuration.expiryInstant ? .verifiedOn : .expiryPassed
            case .expiryPassedServerClockApplies: return .expiryPassed
            case .malformed: return .unknown
            }
        }
        return hasUnresolvedConflict ? .conflict : .unknown
    }

    /// The time of the last verification, shown only while the displayed state is actually verified.
    var verifiedAt: Date? { operationState == .verified ? verifiedSnapshot?.verifiedAt : nil }

    var isOperationInProgress: Bool {
        switch operationState {
        case .loading, .testing, .refreshing, .applying: true
        default: false
        }
    }

    var missingCapabilities: [String] {
        if !reportedMissingCapabilities.isEmpty {
            return Self.requiredExtensions.filter(reportedMissingCapabilities.contains)
        }
        guard let capabilities = verifiedSnapshot?.capabilities, capabilities.isAuthoritative else { return [] }
        return Self.requiredExtensions.filter { !capabilities.supportsSieveExtension($0) }
    }

    var isOutOfOfficeAvailable: Bool { missingCapabilities.isEmpty }

    var capabilityLimitations: [String] {
        var result: [String] = []
        let missing = missingCapabilities
        if missing.contains("vacation") {
            result.append("Out of office is unavailable: this server does not advertise the Sieve extension: vacation.")
        }
        let scheduling = missing.filter { $0 != "vacation" }
        if !scheduling.isEmpty {
            result.append("Scheduled expiry is unavailable: this server does not advertise the Sieve extension(s): \(scheduling.joined(separator: ", ")). SievePilot offers no local fallback, so out of office cannot be enabled.")
        }
        return result
    }

    var canSaveAndActivate: Bool {
        persistedAccount != nil && !isOperationInProgress && isOutOfOfficeAvailable && ruleOrderingAcknowledged
    }

    var canDisable: Bool { persistedAccount != nil && !isOperationInProgress && isOutOfOfficeAvailable }

    var serverDescription: String {
        guard let account = persistedAccount else { return "" }
        switch account.endpointPolicy {
        case .manual(let host, let port): return "\(host):\(port)"
        case .automatic(let domain): return discoveryPreview ?? "Automatic (\(domain))"
        }
    }

    // MARK: Expiry

    static var availableTimeZoneIdentifiers: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }

    var expiryTimeZone: TimeZone { TimeZone(identifier: expiryTimeZoneIdentifier) ?? timeZone }

    /// The expiry as a `Date` for pickers; interpret it in `expiryTimeZone`.
    var expiryPickerDate: Date { calendarInExpiryZone().date(from: expiryLocal) ?? now() }

    func setExpiry(fromPickerDate date: Date) {
        expiryLocal = calendarInExpiryZone().dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    var expiryStatus: ExpiryStatus {
        guard let zone = TimeZone(identifier: expiryTimeZoneIdentifier) else { return .invalidLocalTime }
        do {
            return classify(try ExpiryResolver.resolve(localComponents: expiryLocal, timeZone: zone, repeatedTimeOffset: nil))
        } catch ExpiryResolutionError.repeatedLocalTimeRequiresOffset {
            let options = repeatedOffsets(in: zone)
            if let chosen = repeatedTimeOffset, options.contains(chosen),
               let resolved = try? ExpiryResolver.resolve(localComponents: expiryLocal, timeZone: zone, repeatedTimeOffset: chosen) {
                return classify(resolved)
            }
            return .repeatedLocalTimeNeedsConfirmation(offsets: options)
        } catch ExpiryResolutionError.nonexistentLocalTime {
            return .nonexistentLocalTime
        } catch {
            return .invalidLocalTime
        }
    }

    /// UTC offsets (first occurrence first) when the chosen local time occurs twice; empty otherwise.
    var repeatedTimeOffsetOptions: [Int] {
        guard let zone = TimeZone(identifier: expiryTimeZoneIdentifier) else { return [] }
        do {
            _ = try ExpiryResolver.resolve(localComponents: expiryLocal, timeZone: zone, repeatedTimeOffset: nil)
            return []
        } catch ExpiryResolutionError.repeatedLocalTimeRequiresOffset {
            return repeatedOffsets(in: zone)
        } catch {
            return []
        }
    }

    static func utcOffsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "UTC%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    private enum OutOfOfficeInputError: Error {
        case emptyMessage, nonexistentTime, repeatedTimeUnconfirmed, pastExpiry, invalidExpiry

        var message: String {
            switch self {
            case .emptyMessage: "Enter an out-of-office message."
            case .nonexistentTime: "That local time does not exist because of a daylight-saving change. Choose a different time."
            case .repeatedTimeUnconfirmed: "That local time occurs twice. Choose and confirm the UTC offset."
            case .pastExpiry: "Choose an expiry time in the future."
            case .invalidExpiry: "Choose a valid expiry date, time, and time zone."
            }
        }
    }

    private func outOfOfficeConfigurationFromForm(account: AccountConfiguration) throws -> OutOfOfficeConfiguration {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OutOfOfficeInputError.emptyMessage }
        let expiry: ResolvedExpiry
        switch expiryStatus {
        case .valid(let resolved): expiry = resolved
        case .inPast: throw OutOfOfficeInputError.pastExpiry
        case .nonexistentLocalTime: throw OutOfOfficeInputError.nonexistentTime
        case .repeatedLocalTimeNeedsConfirmation: throw OutOfOfficeInputError.repeatedTimeUnconfirmed
        case .invalidLocalTime: throw OutOfOfficeInputError.invalidExpiry
        }
        return try OutOfOfficeConfiguration(emailAddress: account.emailAddress, subject: subject, message: message, expiry: expiry)
    }

    private func classify(_ resolved: ResolvedExpiry) -> ExpiryStatus {
        resolved.instant > now() ? .valid(resolved) : .inPast(resolved)
    }

    private func repeatedOffsets(in zone: TimeZone) -> [Int] {
        guard let year = expiryLocal.year, let month = expiryLocal.month, let day = expiryLocal.day else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return [] }
        let candidates = Set([zone.secondsFromGMT(for: dayStart), zone.secondsFromGMT(for: dayStart.addingTimeInterval(25 * 3600))])
        return candidates.sorted(by: >).filter {
            (try? ExpiryResolver.resolve(localComponents: expiryLocal, timeZone: zone, repeatedTimeOffset: $0)) != nil
        }
    }

    private func calendarInExpiryZone() -> Calendar {
        var calendar = self.calendar
        calendar.timeZone = expiryTimeZone
        return calendar
    }

    private func formDidChange() { if !isPopulatingForm { formIsDirty = true } }

    private func expiryDidChange() {
        repeatedTimeOffset = nil
        formDidChange()
    }

    private func resetExpiryToDefault() {
        var local = calendar
        local.timeZone = timeZone
        let tomorrow = local.date(byAdding: .day, value: 1, to: now()) ?? now()
        var components = local.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 17
        components.minute = 0
        isPopulatingForm = true
        expiryTimeZoneIdentifier = timeZone.identifier
        expiryLocal = components
        isPopulatingForm = false
        formIsDirty = false
    }

    /// Takes a verified snapshot as the new truth. A pristine form follows the server; user edits are kept.
    private func adopt(_ snapshot: VerifiedAccountSnapshot) {
        verifiedSnapshot = snapshot
        hasUnresolvedConflict = false
        reportedMissingCapabilities = []
        guard !formIsDirty else { return }
        switch snapshot.outOfOfficeState {
        case .on(let configuration), .expiryPassedServerClockApplies(let configuration):
            isPopulatingForm = true
            subject = configuration.subject ?? ""
            message = configuration.message
            expiryLocal = calendarInExpiryZone().dateComponents([.year, .month, .day, .hour, .minute], from: configuration.expiryInstant)
            isPopulatingForm = false
        case .off, .malformed:
            break
        }
    }

    private func applyStaleness(for event: AppLifecycleEvent) {
        switch event {
        case .didResignActive: markStale()
        case .didWake, .networkLost, .networkReconnected: markStale(invalidatingCriticalOperation: true)
        case .didBecomeActive: break
        }
    }

    private func run(_ operation: Operation,
                     _ body: @escaping @MainActor @Sendable (Int) async -> Void) async {
        operationTask?.cancel()
        generation += 1
        let token = generation
        if operation != .refresh { userFacingError = nil }
        invalidatedDuringCritical = false
        operationState = operation.state
        activeOperation = operation
        let pendingCommit = commitTask
        let task = Task { @MainActor [weak self] in
            // A superseded operation may be mid-commit; let it land before reading state again.
            _ = await pendingCommit?.result
            guard let self else { return }
            if Task.isCancelled { finishCancellation(token) } else { await body(token) }
            if isCurrent(token) {
                activeOperation = nil
                operationTask = nil
            }
        }
        operationTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Runs a persistence mutation outside the caller's cancellation so Keychain/settings stay consistent.
    private func commit(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let task = Task { try await work() }
        commitTask = task
        defer { if commitTask == task { commitTask = nil } }
        try await task.value
    }

    private func isCurrent(_ token: Int) -> Bool { generation == token }

    private func finishCancellation(_ token: Int) {
        guard isCurrent(token) else { return }
        operationState = .unknown
    }

    private func finishFailure(_ token: Int, error: Error, fallback: String) {
        if case SieveAccountServiceError.unsupportedCapabilities(let reported) = error, isCurrent(token) {
            let known = Self.requiredExtensions.filter(reported.contains)
            // An empty or unrecognised payload still fails closed and names every requirement.
            let missing = known.isEmpty ? Self.requiredExtensions : known
            reportedMissingCapabilities = missing
            finishFailure(token, message: "This server does not advertise the Sieve extension(s) SievePilot requires: \(missing.joined(separator: ", ")).")
        } else {
            finishFailure(token, message: fallback)
        }
    }

    private func finishFailure(_ token: Int, message: String) {
        guard isCurrent(token) else { return }
        operationState = .error
        userFacingError = message
    }

    private func configurationFromForm() throws -> AccountConfiguration {
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = email.lastIndex(of: "@") else { throw AccountConfigurationError.invalidEmailAddress }
        let domain = String(email[email.index(after: at)...])
        let endpoint: AccountEndpointPolicy
        if usesAutomaticDiscovery {
            endpoint = .automatic(sourceDomain: domain)
        } else {
            guard let port = Int(manualPort) else { throw AccountConfigurationError.invalidEndpoint }
            endpoint = .manual(host: manualHost, port: port)
        }
        return try AccountConfiguration(accountID: persistedAccount?.accountID ?? AccountID(rawValue: UUID()),
                                        emailAddress: email, username: username,
                                        endpointPolicy: endpoint, tlsPolicy: .startTLS)
    }

    private func populateForm(from account: AccountConfiguration) {
        emailAddress = account.emailAddress
        username = account.username
        switch account.endpointPolicy {
        case .automatic:
            usesAutomaticDiscovery = true
            manualHost = ""
        case .manual(let host, let port):
            usesAutomaticDiscovery = false
            manualHost = host
            manualPort = String(port)
        }
    }
}
