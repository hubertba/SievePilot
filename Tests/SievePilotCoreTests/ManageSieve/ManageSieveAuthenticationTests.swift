import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManageSieveAuthenticationTests {
    private let identity = ManageSieveTLSIdentityRequest(referenceIdentifiers: ["mail.example.org"])
    private let greeting = "\"STARTTLS\"\r\nOK\r\n"
    private let secure = "\"IMPLEMENTATION\" \"before\"\r\n\"VERSION\" \"2\"\r\n\"SASL\" \"PLAIN LOGIN\"\r\n\"SIEVE\" \"fileinto\"\r\nOK\r\n"
    private let refreshed = "\"IMPLEMENTATION\" \"after\"\r\n\"VERSION\" \"2\"\r\n\"SASL\" \"PLAIN LOGIN\"\r\n\"SIEVE\" \"fileinto\"\r\nOK\r\n"
    private let username = "test-user-29"
    private let password = "test-secret-47"

    private func setup(_ suffix: [FakeManageSieveTransport.Step], capabilities: String? = nil) -> (FakeManageSieveTransport, ManageSieveClient) {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("OK\r\n".utf8)), .upgrade(identity),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data((capabilities ?? secure).utf8)),
        ] + suffix)
        return (transport, ManageSieveClient(transport: transport, clock: FakeManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: .production, logger: FakeManageSieveLogger()))
    }

    private func plainCommand(_ user: String, _ secret: String) -> Data {
        let payload = Data(([0] as [UInt8]) + Array(user.utf8) + [0] + Array(secret.utf8)).base64EncodedString()
        return Data("AUTHENTICATE \"PLAIN\" \"\(payload)\"\r\n".utf8)
    }

    private func loginResponse(_ value: String) -> Data {
        Data("\"\(Data(value.utf8).base64EncodedString())\"\r\n".utf8)
    }

    private func expectError(_ expected: ManageSieveClientError, _ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected typed error") }
        catch { #expect(error as? ManageSieveClientError == expected) }
    }

    @Test func plainSuccessRequiresCapabilityReacquisition() async throws {
        let (transport, client) = setup([
            .write(plainCommand(username, password)), .read(Data("OK\r\n".utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(refreshed.utf8)),
        ])
        _ = try await client.connectAndStartTLS(identity: identity)
        try await client.authenticatePlain(username: username, password: password)
        #expect(await client.state == .authenticated)
        #expect(await client.capabilities?.implementation == Data("after".utf8))
        #expect(await transport.assertComplete())
    }

    @Test func unsupportedAndInvalidPlainNeverWriteCredentials() async throws {
        let (transport, client) = setup([], capabilities: secure.replacingOccurrences(of: "PLAIN LOGIN", with: "LOGIN"))
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.unsupportedMechanism) { try await client.authenticatePlain(username: username, password: password) }
        #expect(await client.state == .encryptedReady)
        #expect(await transport.assertComplete())
        let (second, other) = setup([])
        _ = try await other.connectAndStartTLS(identity: identity)
        await expectError(.invalidCredentials) { try await other.authenticatePlain(username: "bad\0user", password: password) }
        await expectError(.invalidCredentials) { try await other.authenticatePlain(username: username, password: "bad\0secret") }
        #expect(await second.assertComplete())
    }

    @Test(arguments: [("NO\r\n", ManageSieveClientError.serverNo, ManageSieveClientState.encryptedReady),
                       ("BYE\r\n", .serverBye, .closed)])
    func plainTerminalFailure(wire: String, error: ManageSieveClientError, state: ManageSieveClientState) async throws {
        let (transport, client) = setup([.write(plainCommand(username, password)), .read(Data(wire.utf8))])
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(error) { try await client.authenticatePlain(username: username, password: password) }
        #expect(await client.state == state)
        #expect(await transport.assertComplete())
    }

    @Test(arguments: ["NO\r\n", "\"SASL\" \"PLAIN\"\r\nOK\r\n", "OK 123\r\n"])
    func invalidPostAuthenticationCapabilitiesClose(wire: String) async throws {
        let (transport, client) = setup([
            .write(plainCommand(username, password)), .read(Data("OK\r\n".utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(wire.utf8)),
        ])
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(wire == "NO\r\n" ? .serverNo : .parse) { try await client.authenticatePlain(username: username, password: password) }
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        #expect(await transport.assertComplete())
    }

    @Test func plainPermitsUnicode() async throws {
        let (transport, client) = setup([.write(plainCommand("é🐈", "🔑é")), .read(Data("NO\r\n".utf8))])
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.serverNo) { try await client.authenticatePlain(username: "é🐈", password: "🔑é") }
        #expect(await transport.assertComplete())
    }

    @Test func loginExchangesTwoPositionalChallengesAndRefreshes() async throws {
        let (transport, client) = setup([
            .write(Data("AUTHENTICATE \"LOGIN\"\r\n".utf8)),
            .read(Data("\"\(Data("not a username prompt".utf8).base64EncodedString())\"\r\n".utf8)),
            .write(loginResponse(username)),
            .read(Data("\"\(Data("arbitrary words".utf8).base64EncodedString())\"\r\n".utf8)),
            .write(loginResponse(password)), .read(Data("OK\r\n".utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(refreshed.utf8)),
        ])
        _ = try await client.connectAndStartTLS(identity: identity)
        try await client.authenticateLogin(username: username, password: password)
        #expect(await client.state == .authenticated)
        #expect(await client.capabilities?.implementation == Data("after".utf8))
        #expect(await transport.assertComplete())
    }

    @Test(arguments: ["OK\r\n", "\"!!!!\"\r\n", "\"YQ==\"\r\nOK\r\n"])
    func loginRejectsMissingOrMalformedChallenges(wire: String) async throws {
        let (transport, client) = setup([.write(Data("AUTHENTICATE \"LOGIN\"\r\n".utf8)), .read(Data(wire.utf8))])
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.parse) { try await client.authenticateLogin(username: username, password: password) }
        #expect(await client.state == .closed)
        #expect(await transport.assertComplete())
    }

    @Test func loginRejectsThirdChallenge() async throws {
        let (transport, client) = setup([
            .write(Data("AUTHENTICATE \"LOGIN\"\r\n".utf8)), .read(Data("\"YQ==\"\r\n".utf8)),
            .write(loginResponse(username)), .read(Data("\"Yg==\"\r\n".utf8)),
            .write(loginResponse(password)), .read(Data("\"Yw==\"\r\n".utf8)),
        ])
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.parse) { try await client.authenticateLogin(username: username, password: password) }
        #expect(await client.state == .closed)
        #expect(await transport.assertComplete())
    }

    @Test func loginRejectsUnsupportedAndInvalidCredentials() async throws {
        let (transport, client) = setup([], capabilities: secure.replacingOccurrences(of: "PLAIN LOGIN", with: "PLAIN"))
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.unsupportedMechanism) { try await client.authenticateLogin(username: username, password: password) }
        #expect(await transport.assertComplete())
        let (second, other) = setup([])
        _ = try await other.connectAndStartTLS(identity: identity)
        await expectError(.invalidCredentials) { try await other.authenticateLogin(username: String(repeating: "a", count: 64), password: password) }
        for value in ["a\0b", "a\rb", "a\nb"] {
            await expectError(.invalidCredentials) { try await other.authenticateLogin(username: username, password: value) }
        }
        #expect(await second.assertComplete())
    }

    @Test func authenticationIllegalStateBeforeAndDuringHandshake() async throws {
        let transport = FakeManageSieveTransport([.suspendConnect,
            .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .upgrade(identity), .write(Data("CAPABILITY\r\n".utf8)), .read(Data(secure.utf8)),
        ])
        let client = ManageSieveClient(transport: transport, clock: FakeManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: .production, logger: FakeManageSieveLogger())
        await expectError(.invalidState) { try await client.authenticatePlain(username: username, password: password) }
        let pending = Task { try await client.connectAndStartTLS(identity: identity) }
        while !(await transport.isConnectSuspended) { await Task.yield() }
        await expectError(.invalidState) { try await client.authenticateLogin(username: username, password: password) }
        await transport.resumeConnect()
        _ = try await pending.value
        #expect(await transport.assertComplete())
    }

    @Test(arguments: [("NO\r\n", ManageSieveClientError.serverNo, ManageSieveClientState.encryptedReady),
                       ("BYE\r\n", .serverBye, .closed)])
    func loginTerminalFailure(wire: String, error: ManageSieveClientError, state: ManageSieveClientState) async throws {
        let (transport, client) = setup([
            .write(Data("AUTHENTICATE \"LOGIN\"\r\n".utf8)), .read(Data("\"YQ==\"\r\n".utf8)),
            .write(loginResponse(username)), .read(Data("\"Yg==\"\r\n".utf8)),
            .write(loginResponse(password)), .read(Data(wire.utf8)),
        ])
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(error) { try await client.authenticateLogin(username: username, password: password) }
        #expect(await client.state == state)
        #expect(await transport.assertComplete())
    }

    @Test func authenticateOverlapIsRejectedWithoutAdditionalWrites() async throws {
        let (transport, client) = setup([
            .write(plainCommand(username, password)), .slowRead,
        ])
        _ = try await client.connectAndStartTLS(identity: identity)
        let pending = Task { try await client.authenticatePlain(username: username, password: password, timeout: .seconds(1)) }
        while !(await transport.slowReadStarted) { await Task.yield() }
        await expectError(.invalidState) { try await client.authenticateLogin(username: username, password: password) }
        await expectError(.invalidState) { try await client.capability(); return }
        await expectError(.invalidState) { try await client.authenticatePlain(username: username, password: password) }
        pending.cancel()
        await expectError(.transport) { try await pending.value }
        #expect(await client.state == .closed)
        #expect(await transport.assertComplete())
    }

    @Test func timeoutDuringAuthenticationClosesAndClearsCapabilities() async throws {
        let (transport, _) = setup([.write(plainCommand(username, password)), .slowRead])
        let client = ManageSieveClient(transport: transport, clock: ImmediateManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: .production, logger: FakeManageSieveLogger())
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.timeout) { try await client.authenticatePlain(username: username, password: password) }
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        #expect(await transport.assertComplete())
    }

    @Test func syntheticSecretsNeverAppearInEventsOrErrors() async throws {
        let logger = RecordingManageSieveLogger()
        let (transport, _) = setup([.write(plainCommand(username, password)), .read(Data("NO \"rejected\"\r\n".utf8))])
        let client = ManageSieveClient(transport: transport, clock: FakeManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: .production, logger: logger)
        _ = try await client.connectAndStartTLS(identity: identity)
        var description = ""
        do { try await client.authenticatePlain(username: username, password: password) }
        catch { description = String(describing: error) }
        let reported = logger.events.map { String(describing: $0) }.joined(separator: " ") + description
        for sentinel in [username, password, Data(username.utf8).base64EncodedString(),
                         Data(password.utf8).base64EncodedString(),
                         Data(([0] as [UInt8]) + Array(username.utf8) + [0] + Array(password.utf8)).base64EncodedString(),
                         "rejected"] {
            if reported.contains(sentinel) { Issue.record("Sensitive content leaked into error or log event") }
        }
        #expect(await transport.assertComplete())
    }
}
