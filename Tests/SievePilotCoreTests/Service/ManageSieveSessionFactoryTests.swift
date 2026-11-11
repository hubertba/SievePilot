import Foundation
import XCTest
@testable import SievePilotCore

private actor FactoryCredentialStore: CredentialStoring {
    var value: Data?
    init(_ value: Data?) { self.value = value }
    func read(accountID: AccountID) async throws -> Data? { value }
    func write(_ password: Data, accountID: AccountID) async throws { value = password }
    func delete(accountID: AccountID) async throws { value = nil }
}

private final class FactoryClient: ManageSieveClientSession, @unchecked Sendable {
    private let lock = NSLock()
    let advertised: ManageSieveCapabilities
    var connectError: Error?
    var plainError: Error?
    var loginError: Error?
    private(set) var identities: [ManageSieveTLSIdentityRequest] = []
    private(set) var authentications: [String] = []
    private(set) var logoutCount = 0
    private(set) var closeCount = 0

    init(_ advertised: ManageSieveCapabilities) { self.advertised = advertised }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func connectAndStartTLS(identity: ManageSieveTLSIdentityRequest, timeout: Duration?) async throws -> ManageSieveCapabilities {
        let error = locked { identities.append(identity); return connectError }
        if let error { throw error }
        return advertised
    }
    func authenticatePlain(username: String, password: String, timeout: Duration?) async throws {
        let error = locked { authentications.append("PLAIN:\(username):\(password)"); return plainError }
        if let error { throw error }
    }
    func authenticateLogin(username: String, password: String, timeout: Duration?) async throws {
        let error = locked { authentications.append("LOGIN:\(username):\(password)"); return loginError }
        if let error { throw error }
    }
    var capabilities: ManageSieveCapabilities? { get async { advertised } }
    func listScripts(timeout: Duration?) async throws -> [ManageSieveScriptEntry] { [] }
    func getScript(name: String, timeout: Duration?) async throws -> Data { Data() }
    func checkScript(_ script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { .init(responseCode: nil, message: nil) }
    func putScript(name: String, script: Data, timeout: Duration?) async throws -> ManageSieveCommandResult { .init(responseCode: nil, message: nil) }
    func setActive(name: String, timeout: Duration?) async throws {}
    func deleteScript(name: String, timeout: Duration?) async throws {}
    func logout(timeout: Duration?) async throws { locked { logoutCount += 1 } }
    func close() async { locked { closeCount += 1 } }
}

private final class FactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var discoveries: [String] = []
    private(set) var endpoints: [NIOManageSieveTransport.Endpoint] = []
    private(set) var clients: [FactoryClient] = []
    func recordDiscovery(_ value: String) { lock.lock(); defer { lock.unlock() }; discoveries.append(value) }
    func makeClient(endpoint: NIOManageSieveTransport.Endpoint, capabilities: ManageSieveCapabilities) -> FactoryClient {
        lock.lock(); defer { lock.unlock() }
        endpoints.append(endpoint)
        let client = FactoryClient(capabilities); clients.append(client)
        return client
    }
}

final class ManageSieveSessionFactoryTests: XCTestCase {
    private let accountID = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)

    private func capabilities(sasl: String) throws -> ManageSieveCapabilities {
        let lines = ["IMPLEMENTATION", "VERSION", "SASL", "SIEVE"].map { name -> ManageSieveWireLine in
            let value: String
            switch name { case "SASL": value = sasl; case "SIEVE": value = "vacation date relational"; default: value = "test" }
            return ManageSieveWireLine(tokens: [.string(Data(name.utf8)), .string(Data(value.utf8))])
        }
        return try ManageSieveCapabilities(response: ManageSieveCommandResponse(lines: lines + [ManageSieveWireLine(tokens: [.atom("OK")])]), origin: .postTLSCapability)
    }

    private func account(_ policy: AccountEndpointPolicy) throws -> AccountConfiguration {
        try AccountConfiguration(accountID: accountID, emailAddress: "user@example.org", username: "user",
                                 endpointPolicy: policy, tlsPolicy: .startTLS)
    }

    func testAutomaticAndManualSelectionPreferPlainAndCreateFreshCleanedSessions() async throws {
        let credentials = FactoryCredentialStore(Data("password".utf8))
        let caps = try capabilities(sasl: "LOGIN PLAIN")
        let recorder = FactoryRecorder()
        let factory = ManageSieveSessionFactory(credentialStore: credentials, discover: { email in
            recorder.recordDiscovery(email)
            return SieveServiceEndpoint(host: "srv.example.net", port: 4190,
                                        referenceIdentifiers: [.srv(service: "sieve", domain: "example.org"), .dns("example.org")])
        }, makeClient: { endpoint in recorder.makeClient(endpoint: endpoint, capabilities: caps) })

        _ = try await factory.withAuthenticatedSession(account: account(.automatic(sourceDomain: "example.org"))) { session in
            let sessionCapabilities = await session.capabilities
            XCTAssertEqual(sessionCapabilities, caps)
            return 1
        }
        do {
            let _: Int = try await factory.withAuthenticatedSession(account: account(.manual(host: "mail.example.org", port: 4191))) { _ in
                throw CocoaError(.fileReadUnknown)
            }
            XCTFail()
        } catch { }

        let clients = recorder.clients
        XCTAssertEqual(recorder.discoveries, ["user@example.org"])
        XCTAssertEqual(recorder.endpoints, [.init(host: "srv.example.net", port: 4190), .init(host: "mail.example.org", port: 4191)])
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].identities, [.init(referenceIdentifiers: [.srv(service: "sieve", domain: "example.org"), .dns("example.org")])])
        XCTAssertEqual(clients[1].identities, [.init(referenceIdentifiers: [.dns("mail.example.org")])])
        XCTAssertEqual(clients.map(\.authentications), [["PLAIN:user:password"], ["PLAIN:user:password"]])
        XCTAssertEqual(clients.map(\.logoutCount), [1, 1])
        XCTAssertEqual(clients.map(\.closeCount), [1, 1])
    }

    func testMissingCredentialLoginFallbackAndUnsupportedMechanism() async throws {
        let caps = try capabilities(sasl: "LOGIN")
        let client = FactoryClient(caps)
        let missing = ManageSieveSessionFactory(credentialStore: FactoryCredentialStore(nil), discover: { _ in
            XCTFail("Discovery must not run without credentials"); return .init(host: "x.example", port: 4190, referenceIdentifiers: [])
        }, makeClient: { _ in XCTFail(); return client })
        do { _ = try await missing.withAuthenticatedSession(account: account(.manual(host: "mail.example.org", port: 4190))) { _ in 1 }; XCTFail() }
        catch { XCTAssertEqual(error as? ManageSieveSessionFactoryError, .missingCredential) }

        let factory = ManageSieveSessionFactory(credentialStore: FactoryCredentialStore(Data("password".utf8)), discover: { _ in fatalError() }, makeClient: { _ in client })
        _ = try await factory.withAuthenticatedSession(account: account(.manual(host: "mail.example.org", port: 4190))) { _ in 1 }
        XCTAssertEqual(client.authentications, ["LOGIN:user:password"])

        let unsupportedClient = FactoryClient(try capabilities(sasl: "SCRAM-SHA-256"))
        let unsupported = ManageSieveSessionFactory(credentialStore: FactoryCredentialStore(Data("password".utf8)), discover: { _ in fatalError() }, makeClient: { _ in unsupportedClient })
        do { _ = try await unsupported.withAuthenticatedSession(account: account(.manual(host: "mail.example.org", port: 4190))) { _ in 1 }; XCTFail() }
        catch { XCTAssertEqual(error as? ManageSieveSessionFactoryError, .unsupportedAuthentication) }
        XCTAssertEqual(unsupportedClient.closeCount, 1)
    }

    func testConnectionAndAuthenticationFailuresRemainClassifiedAndClose() async throws {
        let caps = try capabilities(sasl: "PLAIN")
        for (connectError, authError) in [(ManageSieveClientError.tlsIdentityFailed as Error?, nil), (nil, ManageSieveClientError.serverNo as Error?)] {
            let client = FactoryClient(caps); client.connectError = connectError; client.plainError = authError
            let factory = ManageSieveSessionFactory(credentialStore: FactoryCredentialStore(Data("password".utf8)), discover: { _ in fatalError() }, makeClient: { _ in client })
            do { _ = try await factory.withAuthenticatedSession(account: account(.manual(host: "mail.example.org", port: 4190))) { _ in 1 }; XCTFail() }
            catch { XCTAssertEqual(error as? ManageSieveClientError, connectError == nil ? .serverNo : .tlsIdentityFailed) }
            XCTAssertEqual(client.closeCount, 1)
            XCTAssertEqual(client.logoutCount, 0)
        }
    }
}
