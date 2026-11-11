import Combine
import Foundation
import SievePilotCore

@MainActor
final class AppModel: ObservableObject {
    static let productName = "SievePilot"

    enum OperationState: Equatable {
        case idle, loading, testing, refreshing, stale, verified, unknown, error
    }

    @Published var emailAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published var usesAutomaticDiscovery = true
    @Published var manualHost = ""
    @Published var manualPort = "4190"
    @Published private(set) var discoveryPreview: String?
    @Published private(set) var persistedAccount: AccountConfiguration?
    @Published private(set) var operationState: OperationState = .idle
    @Published private(set) var verifiedSnapshot: VerifiedAccountSnapshot?
    @Published var userFacingError: String?

    private enum Operation {
        case load, testAndSave, refresh, delete

        var state: OperationState {
            switch self {
            case .load, .delete: return .loading
            case .testAndSave: return .testing
            case .refresh: return .refreshing
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
    // Reserved for Task 7 (expiry and wake scheduling).
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let timeZone: TimeZone
    private var generation = 0
    private var operationTask: Task<Void, Never>?
    private var activeOperation: Operation?
    private var commitTask: Task<Void, Error>?

    init(settingsStore: any AccountConfigurationStoring,
         persistence: any AccountPersistenceCoordinating,
         discovery: any SieveServiceDiscovering,
         sessionProvider: any ManageSieveCandidateSessionProviding,
         accountService: any SieveAccountServicing,
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current,
         timeZone: TimeZone = .current,
         lifecycle: (any AppLifecycleObserving)? = nil) {
        self.settingsStore = settingsStore
        self.persistence = persistence
        self.discovery = discovery
        self.sessionProvider = sessionProvider
        self.accountService = accountService
        self.now = now
        self.calendar = calendar
        self.timeZone = timeZone
        self.lifecycle = lifecycle
        lifecycle?.start { [weak self] event in
            guard let self else { return }
            if event == .didResignActive { self.markStale() }
            else { Task { await self.handle(event) } }
        }
    }

    convenience init(dependencies: AppDependencies) {
        self.init(settingsStore: dependencies.settingsStore, persistence: dependencies.persistence,
                  discovery: dependencies.discovery, sessionProvider: dependencies.sessionProvider,
                  accountService: dependencies.accountService, lifecycle: dependencies.lifecycle)
    }

    func load() async {
        await run(.load) { [self] token in
            do {
                let account = try await settingsStore.load()
                guard isCurrent(token) else { return }
                persistedAccount = account
                verifiedSnapshot = nil
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
                if isCurrent(token) {
                    password = ""
                    userFacingError = nil
                    operationState = .stale
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
                verifiedSnapshot = snapshot
                userFacingError = nil
                operationState = .verified
            } catch is CancellationError {
                finishCancellation(token)
            } catch {
                finishFailure(token, message: "Unable to verify the server state.")
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
        switch event {
        case .didResignActive: markStale()
        case .didBecomeActive: await refresh()
        }
    }

    /// Invalidates only a verification in flight. Loads and persistence mutations are never dropped here.
    func markStale() {
        guard activeOperation?.isCritical != true else { return }
        operationTask?.cancel()
        operationTask = nil
        activeOperation = nil
        generation += 1
        if persistedAccount != nil { operationState = .stale }
    }

    func dismissError() { userFacingError = nil }

    private func run(_ operation: Operation,
                     _ body: @escaping @MainActor @Sendable (Int) async -> Void) async {
        operationTask?.cancel()
        generation += 1
        let token = generation
        userFacingError = nil
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
        userFacingError = nil
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
