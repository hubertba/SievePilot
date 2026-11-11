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
    func applyOutOfOffice(account: AccountConfiguration,
                          configuration: OutOfOfficeConfiguration?) async throws -> AccountMutationOutcome
}

extension SieveAccountService: SieveAccountServicing {}

struct AppDependencies {
    let settingsStore: any AccountConfigurationStoring
    let persistence: any AccountPersistenceCoordinating
    let discovery: any SieveServiceDiscovering
    let sessionProvider: any ManageSieveSessionProviding
    let accountService: any SieveAccountServicing

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
                               sessionProvider: sessions, accountService: service)
    }
}
