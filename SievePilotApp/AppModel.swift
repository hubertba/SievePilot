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

    private let settingsStore: any AccountConfigurationStoring
    private let persistence: any AccountPersistenceCoordinating
    private let discovery: any SieveServiceDiscovering
    private let sessionProvider: any ManageSieveSessionProviding
    private let accountService: any SieveAccountServicing
    private let now: @Sendable () -> Date
    private var generation = 0

    init(settingsStore: any AccountConfigurationStoring,
         persistence: any AccountPersistenceCoordinating,
         discovery: any SieveServiceDiscovering,
         sessionProvider: any ManageSieveSessionProviding,
         accountService: any SieveAccountServicing,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.settingsStore = settingsStore
        self.persistence = persistence
        self.discovery = discovery
        self.sessionProvider = sessionProvider
        self.accountService = accountService
        self.now = now
    }

    convenience init(dependencies: AppDependencies) {
        self.init(settingsStore: dependencies.settingsStore, persistence: dependencies.persistence,
                  discovery: dependencies.discovery, sessionProvider: dependencies.sessionProvider,
                  accountService: dependencies.accountService)
    }

    func load() async {
        let token = begin(.loading)
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

    func testAndSave() async {
        let token = begin(.testing)
        do {
            let configuration = try configurationFromForm()
            if usesAutomaticDiscovery {
                let endpoint = try await discovery.discover(emailAddress: configuration.emailAddress)
                guard isCurrent(token) else { return }
                discoveryPreview = "\(endpoint.host):\(endpoint.port)"
            } else {
                discoveryPreview = nil
            }
            _ = try await sessionProvider.withAuthenticatedSession(account: configuration) { _ in true }
            guard isCurrent(token) else { return }
            try await persistence.save(configuration: configuration, password: Data(password.utf8))
            guard isCurrent(token) else { return }
            persistedAccount = configuration
            password = ""
            verifiedSnapshot = nil
            userFacingError = nil
            operationState = .stale
        } catch is CancellationError {
            finishCancellation(token)
        } catch is AccountConfigurationError {
            finishFailure(token, message: "Enter a valid email address, username, and server configuration.")
        } catch {
            finishFailure(token, message: "Unable to verify and save this account.")
        }
    }

    func refresh() async {
        guard let account = persistedAccount else { return }
        let token = begin(.refreshing)
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

    func deleteAccount() async {
        guard let account = persistedAccount else { return }
        let token = begin(.loading)
        do {
            try await persistence.delete(accountID: account.accountID)
            guard isCurrent(token) else { return }
            persistedAccount = nil
            verifiedSnapshot = nil
            discoveryPreview = nil
            password = ""
            userFacingError = nil
            operationState = .idle
        } catch is CancellationError {
            finishCancellation(token)
        } catch {
            finishFailure(token, message: "Unable to delete this account.")
        }
    }

    func markStale() {
        generation += 1
        if persistedAccount != nil { operationState = .stale }
    }

    func dismissError() { userFacingError = nil }

    private func begin(_ state: OperationState) -> Int {
        generation += 1
        userFacingError = nil
        operationState = state
        return generation
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
