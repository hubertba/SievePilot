import Foundation

public protocol CredentialStoring: Sendable {
    func read(accountID: AccountID) async throws -> Data?
    func write(_ password: Data, accountID: AccountID) async throws
    func delete(accountID: AccountID) async throws
}

public enum AccountPersistenceError: Error, Equatable, Sendable {
    case credentialReadFailed
    case credentialWriteFailed
    case settingsSaveFailed
    case settingsDeleteFailed
    case credentialDeleteFailed
    case inconsistentState
}

public actor AccountPersistenceCoordinator {
    private let configurationStore: any AccountConfigurationStoring
    private let credentialStore: any CredentialStoring

    public init(configurationStore: any AccountConfigurationStoring, credentialStore: any CredentialStoring) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
    }

    public func save(configuration: AccountConfiguration, password: Data) async throws {
        let priorCredential: Data?
        do { priorCredential = try await credentialStore.read(accountID: configuration.accountID) }
        catch { throw AccountPersistenceError.credentialReadFailed }
        do { try await credentialStore.write(password, accountID: configuration.accountID) }
        catch { throw AccountPersistenceError.credentialWriteFailed }
        do {
            try await configurationStore.save(configuration)
        } catch {
            do {
                if let priorCredential {
                    try await credentialStore.write(priorCredential, accountID: configuration.accountID)
                } else {
                    try await credentialStore.delete(accountID: configuration.accountID)
                }
            } catch {
                throw AccountPersistenceError.inconsistentState
            }
            throw AccountPersistenceError.settingsSaveFailed
        }
    }

    public func delete(accountID: AccountID) async throws {
        do { try await configurationStore.delete() }
        catch { throw AccountPersistenceError.settingsDeleteFailed }
        do { try await credentialStore.delete(accountID: accountID) }
        catch { throw AccountPersistenceError.credentialDeleteFailed }
    }
}
