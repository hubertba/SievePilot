import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import XCTest
@testable import SievePilotCore

// Default (never skipped) loopback interoperability: the real `ManageSieveClient` over the real
// `NIOManageSieveTransport`, against a local server that speaks an RFC 5804-shaped STARTTLS transcript.
// The server re-issues its capabilities unsolicited once TLS is established (RFC 5804 §2.2) and answers
// every command it receives, so a client that sends a competing CAPABILITY desynchronises here exactly as
// it would against a compliant server. No credentials, environment variables, or external hosts are used.

/// Event-loop confined except for `commands`, which is lock-protected for the test thread.
private final class RFC5804LoopbackServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    // Before TLS the server offers no SASL mechanism, so only the post-TLS list permits authentication.
    static let greeting = "\"IMPLEMENTATION\" \"Loopback ManageSieved\"\r\n\"SASL\" \"\"\r\n\"SIEVE\" \"fileinto\"\r\n"
        + "\"STARTTLS\"\r\nOK \"ManageSieve ready.\"\r\n"
    static let capabilities = "\"IMPLEMENTATION\" \"Loopback ManageSieved\"\r\n\"VERSION\" \"1.0\"\r\n"
        + "\"SASL\" \"PLAIN\"\r\n\"SIEVE\" \"fileinto vacation date relational\"\r\n"

    private let lock = NSLock()
    private var storedCommands: [String] = []
    private var tlsContext: NIOSSLContext?
    private let acceptedAuthenticate: String
    private var encrypted = false
    private var authenticated = false
    private var pending = Data()

    init(tlsContext: NIOSSLContext, username: String, password: String) {
        self.tlsContext = tlsContext
        let payload = Data(([0] as [UInt8]) + Array(username.utf8) + [0] + Array(password.utf8)).base64EncodedString()
        acceptedAuthenticate = "AUTHENTICATE \"PLAIN\" \"\(payload)\""
    }

    /// Command names in arrival order. Authentication payloads are never recorded.
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return storedCommands }

    private func record(_ command: String) { lock.lock(); storedCommands.append(command); lock.unlock() }

    private func send(_ text: String, context: ChannelHandlerContext) {
        context.writeAndFlush(NIOAny(ByteBuffer(string: text)), promise: nil)
    }

    func channelActive(context: ChannelHandlerContext) {
        send(Self.greeting, context: context)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            encrypted = true
            // RFC 5804 §2.2: capabilities are re-issued, followed by OK, without any client command.
            send(Self.capabilities + "OK \"TLS negotiation successful.\"\r\n", context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        while let terminator = pending.range(of: Data("\r\n".utf8)) {
            let line = String(decoding: pending[pending.startIndex..<terminator.lowerBound], as: UTF8.self)
            pending.removeSubrange(pending.startIndex..<terminator.upperBound)
            handle(line, context: context)
        }
    }

    private func handle(_ line: String, context: ChannelHandlerContext) {
        if line.hasPrefix("AUTHENTICATE") {
            record("AUTHENTICATE")
            guard encrypted, !authenticated, line == acceptedAuthenticate else {
                send("NO \"Authentication failed.\"\r\n", context: context)
                return
            }
            authenticated = true
            send("OK \"Logged in.\"\r\n", context: context)
            return
        }
        record(line)
        switch line {
        case "STARTTLS":
            guard let tlsContext else { send("NO \"TLS is already active.\"\r\n", context: context); return }
            self.tlsContext = nil
            send("OK \"Begin TLS negotiation now.\"\r\n", context: context)
            do { try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tlsContext), position: .before(self)) }
            catch { XCTFail("Server TLS insertion failed"); context.close(promise: nil) }
        case "CAPABILITY":
            send(Self.capabilities + "OK \"Capability completed.\"\r\n", context: context)
        case "LISTSCRIPTS" where authenticated:
            send("\"main\" ACTIVE\r\n\"backup\"\r\nOK \"Listscripts completed.\"\r\n", context: context)
        case "LOGOUT":
            context.writeAndFlush(NIOAny(ByteBuffer(string: "OK \"Logout completed.\"\r\n"))).whenComplete { _ in
                context.close(promise: nil)
            }
        default:
            send("NO \"Command not available.\"\r\n", context: context)
        }
    }
}

final class ManageSieveLoopbackInteropTests: XCTestCase {
    private let username = "loopback-user"
    private let password = "loopback-password"
    private let sourceDomain = "source.example.org"

    private var referenceIdentifiers: [ManageSieveReferenceIdentifier] {
        [.srv(service: "sieve", domain: sourceDomain), .dns(sourceDomain)]
    }

    private func startServer(group: EventLoopGroup, fragmented: Bool) throws -> (Channel, RFC5804LoopbackServer) {
        let certificate = try NIOSSLCertificate(bytes: Array(tlsFixture("server.der")), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(tlsFixture("server-key.pem")), format: .pem)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)))
        let server = RFC5804LoopbackServer(tlsContext: context, username: username, password: password)
        let listener = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(NIOManageSieveTransportTests.FragmentTLSWrites(enabled: fragmented))
                    try channel.pipeline.syncOperations.addHandler(server)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.bind(host: "127.0.0.1", port: 0).wait()
        return (listener, server)
    }

    private func transport(port: Int, group: EventLoopGroup) -> NIOManageSieveTransport {
        NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: port), eventLoopGroup: group,
                                trustEvaluator: FixtureTLSChainTrustEvaluator())
    }

    private func shutdown(_ group: EventLoopGroup) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }

    private func account() throws -> AccountConfiguration {
        try AccountConfiguration(accountID: AccountID(rawValue: UUID()), emailAddress: "user@\(sourceDomain)",
                                 username: username, endpointPolicy: .automatic(sourceDomain: sourceDomain), tlsPolicy: .startTLS)
    }

    /// The production session factory with the real client session; only DNS discovery and the trust
    /// anchor are replaced so the loopback fixture certificate can be validated.
    private func factory(port: Int, group: EventLoopGroup, storedPassword: String,
                         identifiers: [ManageSieveReferenceIdentifier]? = nil,
                         trustEvaluator: any TLSChainTrustEvaluating = FixtureTLSChainTrustEvaluator()) -> ManageSieveSessionFactory {
        let identifiers = identifiers ?? referenceIdentifiers
        return ManageSieveSessionFactory(
            credentialStore: LoopbackCredentialStore(password: Data(storedPassword.utf8)),
            discover: { _ in SieveServiceEndpoint(host: "127.0.0.1", port: port, referenceIdentifiers: identifiers) },
            makeClient: { endpoint in
                RealManageSieveClientSession(transport: NIOManageSieveTransport(
                    endpoint: endpoint, eventLoopGroup: group, trustEvaluator: trustEvaluator))
            })
    }

    func testRealClientOverRealTransportConsumesUnsolicitedCapabilitiesThenAuthenticatesListsAndLogsOut() async throws {
        for fragmented in [false, true] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let (listener, server) = try startServer(group: group, fragmented: fragmented)
            let client = ManageSieveClient(
                transport: transport(port: listener.localAddress!.port!, group: group), clock: LoopbackClock(),
                timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(10), startTLS: .seconds(10),
                                                        authentication: .seconds(10), command: .seconds(10)),
                limits: .production, logger: FakeManageSieveLogger())

            let postTLS = try await client.connectAndStartTLS(identity: .init(referenceIdentifiers: referenceIdentifiers))
            XCTAssertTrue(postTLS.isAuthoritative)
            XCTAssertTrue(postTLS.supportsSASLMechanism("PLAIN"), "SASL must come from the post-TLS block, not the greeting")
            XCTAssertEqual(server.commands, ["STARTTLS"], "No command may be sent before the unsolicited block is consumed")

            try await client.authenticatePlain(username: username, password: password)
            let state = await client.state
            XCTAssertEqual(state, .authenticated)
            let scripts = try await client.listScripts()
            XCTAssertEqual(scripts, [ManageSieveScriptEntry(name: "main", isActive: true),
                                     ManageSieveScriptEntry(name: "backup", isActive: false)])
            try await client.logout()
            XCTAssertEqual(server.commands, ["STARTTLS", "AUTHENTICATE", "CAPABILITY", "LISTSCRIPTS", "LOGOUT"])

            try await listener.close().get()
            await shutdown(group)
        }
    }

    func testProductionSessionFactoryCompositionCompletesRFC5804Transcript() async throws {
        for fragmented in [false, true] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let (listener, server) = try startServer(group: group, fragmented: fragmented)
            let factory = factory(port: listener.localAddress!.port!, group: group, storedPassword: password)

            let result: (capabilities: ManageSieveCapabilities, scripts: [ManageSieveScriptEntry]) =
                try await factory.withAuthenticatedSession(account: account()) { session in
                    (await session.capabilities, try await session.listScripts(timeout: nil))
                }
            XCTAssertTrue(result.capabilities.isAuthoritative)
            XCTAssertEqual(result.capabilities.version, Data("1.0".utf8))
            for name in ["vacation", "date", "relational"] { XCTAssertTrue(result.capabilities.supportsSieveExtension(name), name) }
            XCTAssertEqual(result.scripts.map(\.name), ["main", "backup"])
            XCTAssertEqual(result.scripts.first(where: \.isActive)?.name, "main")
            XCTAssertEqual(server.commands, ["STARTTLS", "AUTHENTICATE", "CAPABILITY", "LISTSCRIPTS", "LOGOUT"])

            try await listener.close().get()
            await shutdown(group)
        }
    }

    func testRefusedAuthenticateIsAnAuthenticationRejectionThroughTheRealComposition() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (listener, server) = try startServer(group: group, fragmented: false)
        let factory = factory(port: listener.localAddress!.port!, group: group, storedPassword: "not-the-password")
        do {
            _ = try await factory.withAuthenticatedSession(account: account()) { _ in 1 }
            XCTFail("A refused AUTHENTICATE must not open a session")
        } catch {
            XCTAssertEqual(error as? ManageSieveSessionFactoryError, .authenticationRejected)
            XCTAssertFalse(String(reflecting: error).contains("Authentication failed"), "Server text must not be carried")
        }
        XCTAssertEqual(server.commands, ["STARTTLS", "AUTHENTICATE"])
        try await listener.close().get()
        await shutdown(group)
    }

    func testTrustAndIdentityFailuresStayDistinctAndPrecedeAuthenticationThroughTheRealComposition() async throws {
        let cases: [(trust: any TLSChainTrustEvaluating, identifiers: [ManageSieveReferenceIdentifier], expected: ManageSieveClientError)] = [
            (FixtureTLSChainTrustEvaluator(trusted: false), referenceIdentifiers, .tlsTrustFailed),
            (FixtureTLSChainTrustEvaluator(), [.srv(service: "sieve", domain: "other.example.org"), .dns("other.example.org")], .tlsIdentityFailed),
        ]
        for (trust, identifiers, expected) in cases {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let (listener, server) = try startServer(group: group, fragmented: false)
            let factory = factory(port: listener.localAddress!.port!, group: group, storedPassword: password,
                                  identifiers: identifiers, trustEvaluator: trust)
            do {
                _ = try await factory.withAuthenticatedSession(account: account()) { _ in 1 }
                XCTFail("Expected \(expected)")
            } catch { XCTAssertEqual(error as? ManageSieveClientError, expected) }
            XCTAssertEqual(server.commands, ["STARTTLS"], "Credentials must never be sent after a TLS failure")
            try await listener.close().get()
            await shutdown(group)
        }
    }
}

private struct LoopbackCredentialStore: CredentialStoring {
    let password: Data
    func read(accountID: AccountID) async throws -> Data? { password }
    func write(_ password: Data, accountID: AccountID) async throws {}
    func delete(accountID: AccountID) async throws {}
}

private struct LoopbackClock: ManageSieveClock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
