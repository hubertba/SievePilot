import Foundation
import SievePilotCore

protocol AccountPersistenceCoordinating: Sendable {
    func save(configuration: AccountConfiguration, password: Data) async throws
    func delete(accountID: AccountID) async throws
}

extension AccountPersistenceCoordinator: AccountPersistenceCoordinating {}

protocol SieveServiceDiscovering: Sendable {
    func discover(emailAddress: String) async throws -> SieveServiceEndpoint
}

extension SieveServiceDiscovery: SieveServiceDiscovering {}

protocol SieveAccountServicing: Sendable {
    func refresh(account: AccountConfiguration) async throws -> VerifiedAccountSnapshot
    func getScript(account: AccountConfiguration, name: String) async throws -> Data
    func deleteScript(account: AccountConfiguration, name: String) async throws -> ScriptDeletionOutcome
    func applyOutOfOffice(account: AccountConfiguration,
                          configuration: OutOfOfficeConfiguration?) async throws -> AccountMutationOutcome
}

extension SieveAccountService: SieveAccountServicing {}

/// Remembers, per account, that the user has read the first-activation rule-order notice.
protocol ActivationAcknowledgementStoring: AnyObject, Sendable {
    func hasAcknowledged(_ accountID: AccountID) -> Bool
    func acknowledge(_ accountID: AccountID)
}

final class UserDefaultsActivationAcknowledgementStore: ActivationAcknowledgementStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ id: AccountID) -> String { "ruleOrderingAcknowledged.\(id.rawValue.uuidString)" }
    func hasAcknowledged(_ accountID: AccountID) -> Bool { defaults.bool(forKey: key(accountID)) }
    func acknowledge(_ accountID: AccountID) { defaults.set(true, forKey: key(accountID)) }
}

final class InMemoryActivationAcknowledgementStore: ActivationAcknowledgementStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledged: Set<AccountID> = []
    func hasAcknowledged(_ accountID: AccountID) -> Bool { lock.lock(); defer { lock.unlock() }; return acknowledged.contains(accountID) }
    func acknowledge(_ accountID: AccountID) { lock.lock(); acknowledged.insert(accountID); lock.unlock() }
}

struct AppDependencies {
    let settingsStore: any AccountConfigurationStoring
    let persistence: any AccountPersistenceCoordinating
    let discovery: any SieveServiceDiscovering
    let sessionProvider: any ManageSieveCandidateSessionProviding
    let accountService: any SieveAccountServicing
    let lifecycle: any AppLifecycleObserving
    let acknowledgements: any ActivationAcknowledgementStoring

    @MainActor
    static func production() -> AppDependencies {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let settings = AccountConfigurationStore(baseDirectory: baseDirectory)
        let credentials = KeychainCredentialStore()
        let persistence = AccountPersistenceCoordinator(configurationStore: settings, credentialStore: credentials)
        let discovery = SieveServiceDiscovery(resolver: DNSServiceResolver(), random: SystemSieveRandomSource())
        let sessions = ManageSieveSessionFactory(credentialStore: credentials)
        let manifests = OwnedScriptManifestStore(baseDirectory: baseDirectory)
        let service = SieveAccountService(sessionProvider: sessions, manifestStore: manifests)
        return AppDependencies(settingsStore: settings, persistence: persistence, discovery: discovery,
                               sessionProvider: sessions, accountService: service,
                               lifecycle: AppLifecycleCoordinator(),
                               acknowledgements: UserDefaultsActivationAcknowledgementStore())
    }
}
