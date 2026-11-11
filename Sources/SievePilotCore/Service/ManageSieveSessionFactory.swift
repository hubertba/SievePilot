import Foundation

public protocol AuthenticatedManageSieveSession: Sendable {
    var capabilities: ManageSieveCapabilities { get async }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry]
    func getScript(name: String, timeout: Duration?) async throws -> Data
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult
    func setActive(name: String, timeout: Duration?) async throws
    func deleteScript(name: String, timeout: Duration?) async throws
}

public protocol ManageSieveSessionProviding: Sendable {
    func withAuthenticatedSession<T: Sendable>(
        account: AccountConfiguration,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T
    ) async throws -> T
}

/// Opens a session authenticated with a candidate password supplied by the caller
/// (for example, an unsaved setup form) without reading or writing stored credentials.
public protocol ManageSieveCandidateSessionProviding: Sendable {
    func withAuthenticatedSession<T: Sendable>(
        account: AccountConfiguration,
        password: Data,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T
    ) async throws -> T
}

public enum ManageSieveSessionFactoryError: Error, Equatable, Sendable {
    case missingCredential
    case invalidCredentialEncoding
    case unsupportedAuthentication
}

internal protocol ManageSieveClientSession: Sendable {
    func connectAndStartTLS(identity: ManageSieveTLSIdentityRequest, timeout: Duration?) async throws -> ManageSieveCapabilities
    func authenticatePlain(username: String, password: String, timeout: Duration?) async throws
    func authenticateLogin(username: String, password: String, timeout: Duration?) async throws
    var capabilities: ManageSieveCapabilities? { get async }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry]
    func getScript(name: String, timeout: Duration?) async throws -> Data
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult
    func setActive(name: String, timeout: Duration?) async throws
    func deleteScript(name: String, timeout: Duration?) async throws
    func logout(timeout: Duration?) async throws
    func close() async
}

public struct ManageSieveSessionFactory: ManageSieveSessionProviding, ManageSieveCandidateSessionProviding, @unchecked Sendable {
    private let credentialStore: any CredentialStoring
    private let discover: @Sendable (String) async throws -> SieveServiceEndpoint
    private let makeClient: @Sendable (NIOManageSieveTransport.Endpoint) -> any ManageSieveClientSession

    public init(credentialStore: any CredentialStoring) {
        let discovery = SieveServiceDiscovery(resolver: DNSServiceResolver(), random: SystemSieveRandomSource())
        self.init(credentialStore: credentialStore, discover: { try await discovery.discover(emailAddress: $0) }) { endpoint in
            RealManageSieveClientSession(endpoint: endpoint)
        }
    }

    internal init(credentialStore: any CredentialStoring,
                  discover: @escaping @Sendable (String) async throws -> SieveServiceEndpoint,
                  makeClient: @escaping @Sendable (NIOManageSieveTransport.Endpoint) -> any ManageSieveClientSession) {
        self.credentialStore = credentialStore
        self.discover = discover
        self.makeClient = makeClient
    }

    public func withAuthenticatedSession<T: Sendable>(account: AccountConfiguration,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T) async throws -> T {
        guard var passwordData = try await credentialStore.read(accountID: account.accountID) else {
            throw ManageSieveSessionFactoryError.missingCredential
        }
        defer { passwordData.resetBytes(in: 0..<passwordData.count) }
        return try await authenticatedSession(account: account, passwordData: passwordData, operation)
    }

    public func withAuthenticatedSession<T: Sendable>(account: AccountConfiguration, password: Data,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T) async throws -> T {
        var passwordData = password
        defer { passwordData.resetBytes(in: 0..<passwordData.count) }
        return try await authenticatedSession(account: account, passwordData: passwordData, operation)
    }

    private func authenticatedSession<T: Sendable>(account: AccountConfiguration, passwordData: Data,
        _ operation: @Sendable (any AuthenticatedManageSieveSession) async throws -> T) async throws -> T {
        guard let password = String(data: passwordData, encoding: .utf8) else {
            throw ManageSieveSessionFactoryError.invalidCredentialEncoding
        }

        let serviceEndpoint: SieveServiceEndpoint
        switch account.endpointPolicy {
        case .automatic:
            serviceEndpoint = try await discover(account.emailAddress)
        case .manual(let host, let port):
            serviceEndpoint = SieveServiceEndpoint(host: host, port: port, referenceIdentifiers: [.dns(host)])
        }
        let client = makeClient(.init(host: serviceEndpoint.host, port: serviceEndpoint.port))
        let authenticatedCapabilities: ManageSieveCapabilities
        do {
            let advertised = try await client.connectAndStartTLS(
                identity: .init(referenceIdentifiers: serviceEndpoint.referenceIdentifiers), timeout: nil)
            if advertised.supportsSASLMechanism("PLAIN") {
                try await client.authenticatePlain(username: account.username, password: password, timeout: nil)
            } else if advertised.supportsSASLMechanism("LOGIN") {
                try await client.authenticateLogin(username: account.username, password: password, timeout: nil)
            } else {
                throw ManageSieveSessionFactoryError.unsupportedAuthentication
            }
            guard let capabilities = await client.capabilities, capabilities.isAuthoritative else {
                throw ManageSieveClientError.parse
            }
            authenticatedCapabilities = capabilities
        } catch {
            await client.close()
            throw error
        }
        let session = AuthenticatedSessionAdapter(client: client, capabilities: authenticatedCapabilities)
        do {
            let value = try await operation(session)
            try? await client.logout(timeout: nil)
            await client.close()
            return value
        } catch {
            try? await client.logout(timeout: nil)
            await client.close()
            throw error
        }
    }
}

private struct AuthenticatedSessionAdapter: AuthenticatedManageSieveSession {
    let client: any ManageSieveClientSession
    let capabilities: ManageSieveCapabilities
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry] { try await client.listScripts(timeout: timeout) }
    func getScript(name: String, timeout: Duration?) async throws -> Data { try await client.getScript(name: name, timeout: timeout) }
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { try await client.checkScript(script, timeout: timeout) }
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { try await client.putScript(name: name, script: script, timeout: timeout) }
    func setActive(name: String, timeout: Duration?) async throws { try await client.setActive(name: name, timeout: timeout) }
    func deleteScript(name: String, timeout: Duration?) async throws { try await client.deleteScript(name: name, timeout: timeout) }
}

private final class RealManageSieveClientSession: ManageSieveClientSession, @unchecked Sendable {
    private let client: ManageSieveClient
    init(endpoint: NIOManageSieveTransport.Endpoint) {
        client = ManageSieveClient(transport: NIOManageSieveTransport(endpoint: endpoint), clock: SystemManageSieveClock(),
                                   timeoutPolicy: .production, limits: .production, logger: SilentManageSieveLogger())
    }
    var capabilities: ManageSieveCapabilities? { get async { await client.capabilities } }
    func connectAndStartTLS(identity: ManageSieveTLSIdentityRequest, timeout: Duration?) async throws -> ManageSieveCapabilities { try await client.connectAndStartTLS(identity: identity, timeout: timeout) }
    func authenticatePlain(username: String, password: String, timeout: Duration?) async throws { try await client.authenticatePlain(username: username, password: password, timeout: timeout) }
    func authenticateLogin(username: String, password: String, timeout: Duration?) async throws { try await client.authenticateLogin(username: username, password: password, timeout: timeout) }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry] { try await client.listScripts(timeout: timeout) }
    func getScript(name: String, timeout: Duration?) async throws -> Data { try await client.getScript(name: name, timeout: timeout) }
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { try await client.checkScript(script, timeout: timeout) }
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { try await client.putScript(name: name, script: script, timeout: timeout) }
    func setActive(name: String, timeout: Duration?) async throws { try await client.setActive(name: name, timeout: timeout) }
    func deleteScript(name: String, timeout: Duration?) async throws { try await client.deleteScript(name: name, timeout: timeout) }
    func logout(timeout: Duration?) async throws { try await client.logout(timeout: timeout) }
    func close() async { await client.close() }
}

private struct SystemManageSieveClock: ManageSieveClock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
private struct SilentManageSieveLogger: ManageSieveLogger { func record(_ event: ManageSieveLogEvent) {} }

private extension ManageSieveTimeoutPolicy {
    static let production = ManageSieveTimeoutPolicy(connect: .seconds(10), startTLS: .seconds(10),
                                                     authentication: .seconds(10), command: .seconds(15))
}
