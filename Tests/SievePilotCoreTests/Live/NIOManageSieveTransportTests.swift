import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import NIOTLS
import XCTest
@testable import SievePilotCore

final class NIOManageSieveTransportTests: XCTestCase {
    private final class ServerRecorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let lock = NSLock()
        private var storedChannel: Channel?
        private var storedBytes = Data()
        private var startTLSContext: NIOSSLContext?
        private let unsolicitedPostTLS: String?
        init(startTLSContext: NIOSSLContext? = nil, unsolicitedPostTLS: String? = nil) {
            self.startTLSContext = startTLSContext
            self.unsolicitedPostTLS = unsolicitedPostTLS
        }
        var channel: Channel? { lock.lock(); defer { lock.unlock() }; return storedChannel }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return storedBytes }
        func channelActive(context: ChannelHandlerContext) {
            lock.lock(); storedChannel = context.channel; lock.unlock()
            if startTLSContext != nil { context.writeAndFlush(NIOAny(ByteBuffer(string: "\"STARTTLS\"\r\nOK\r\n")), promise: nil) }
            context.fireChannelActive()
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            lock.lock(); storedBytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            let command = storedBytes
            lock.unlock()
            if let sslContext = startTLSContext, command == Data("STARTTLS\r\n".utf8) {
                lock.lock(); storedBytes.removeAll(); lock.unlock()
                startTLSContext = nil
                context.writeAndFlush(NIOAny(ByteBuffer(string: "OK\r\n")), promise: nil)
                do { try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext), position: .before(self)) }
                catch { XCTFail("Server TLS insertion failed"); context.close(promise: nil) }
            }
        }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            // RFC 5804 §2.2: the server re-issues its capabilities, unsolicited, as soon as TLS is established.
            if case .handshakeCompleted = event as? TLSUserEvent, let unsolicitedPostTLS {
                context.writeAndFlush(NIOAny(ByteBuffer(string: unsolicitedPostTLS)), promise: nil)
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    private static let unsolicitedPostTLSCapabilities =
        "\"IMPLEMENTATION\" \"loopback\"\r\n\"VERSION\" \"1.0\"\r\n\"SASL\" \"PLAIN\"\r\n\"SIEVE\" \"fileinto vacation\"\r\nOK \"TLS negotiation successful.\"\r\n"

    private func server(group: EventLoopGroup, recorder: ServerRecorder) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(recorder) }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    private func shutdown(_ group: EventLoopGroup) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testConnectFragmentedReadsBoundedSplittingOrderedWritesAndEOF() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        await waitUntil { recorder.channel != nil }
        let peer = try XCTUnwrap(recorder.channel)
        try await peer.writeAndFlush(ByteBuffer(string: "ab")).get()
        let first = try await transport.read(maxBytes: 1)
        XCTAssertEqual(first, Data("a".utf8))
        try await peer.writeAndFlush(ByteBuffer(string: "cdef")).get()
        var remainder = Data()
        while remainder.count < 5 {
            let part = try await transport.read(maxBytes: 2)
            XCTAssertLessThanOrEqual(part.count, 2)
            remainder.append(part)
        }
        XCTAssertEqual(remainder, Data("bcdef".utf8))
        try await transport.write(Data("first".utf8))
        try await transport.write(Data("second".utf8))
        await waitUntil { recorder.bytes.count == 11 }
        XCTAssertEqual(recorder.bytes, Data("firstsecond".utf8))
        try await peer.close().get()
        let eof = try await transport.read(maxBytes: 10)
        XCTAssertEqual(eof, Data())
        await transport.close()
        await transport.close()
        try await listener.close().get()
        await shutdown(group)
    }

    private func injectChannelError(into transport: NIOManageSieveTransport) throws {
        // Drive the real inbound handler without relying on OS-specific socket error delivery.
        let channel = EmbeddedChannel(handler: NIOManageSieveTransport.InboundHandler(owner: transport))
        channel.pipeline.fireErrorCaught(NSError(domain: "private-socket-detail", code: 1))
        XCTAssertFalse(channel.isActive)
        XCTAssertTrue(try channel.finish(acceptAlreadyClosed: true).isClean)
    }

    func testPlaintextChannelErrorPreservesEOFAndSanitizedCloseInsteadOfTLSFailure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try server(group: group, recorder: ServerRecorder())
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()

        try injectChannelError(into: transport)
        do {
            let eof = try await transport.read(maxBytes: 1)
            XCTAssertEqual(eof, Data())
        } catch { XCTFail("Plaintext channel errors must preserve EOF, not fail with \(error)") }
        await transport.close()
        await transport.close()
        do { _ = try await transport.read(maxBytes: 1); XCTFail("Expected closed") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        do { try await transport.write(Data("secret".utf8)); XCTFail("Expected closed") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        try await listener.close().get()
        await shutdown(group)
    }

    func testChannelErrorDuringActiveTLSUpgradeRemainsHandshakeFailure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        let pending = Task { try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("source.example.org")])) }
        await waitUntil { !recorder.bytes.isEmpty }

        try injectChannelError(into: transport)
        do { try await pending.value; XCTFail("Expected handshake failure") }
        catch { XCTAssertEqual(error as? NIOTransportError, .tlsHandshakeFailed) }
        await transport.close()
        await transport.close()
        do { try await transport.write(Data("secret".utf8)); XCTFail("Expected terminal failure") }
        catch { XCTAssertEqual(error as? NIOTransportError, .tlsHandshakeFailed) }
        try await listener.close().get()
        await shutdown(group)
    }

    func testConnectFailureAndInvalidReadAreSanitized() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try server(group: group, recorder: ServerRecorder())
        let port = listener.localAddress!.port!
        try await listener.close().get()
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: port), eventLoopGroup: group)
        do { try await transport.connect(); XCTFail("Expected failure") }
        catch { XCTAssertFalse(String(describing: error).contains("127.0.0.1")) }
        await transport.close()
        await shutdown(group)
    }

    func testCloseReleasesPendingReadAndRejectsFurtherOperations() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        let pending = Task { try await transport.read(maxBytes: 10) }
        await transport.close()
        do { _ = try await pending.value; XCTFail("Expected closed") } catch { XCTAssertTrue(error is NIOTransportError) }
        do { try await transport.write(Data("password-secret".utf8)); XCTFail("Expected closed") }
        catch { XCTAssertFalse(String(describing: error).contains("password-secret")) }
        // An externally supplied group remains usable after transport closure.
        let stillUsable = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: listener.localAddress!.port!).get()
        XCTAssertTrue(stillUsable.isActive)
        try await stillUsable.close().get()
        try await listener.close().get()
        await shutdown(group)
    }

    func testCloseReleasesPendingConnectDespiteIgnoredCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let gate = DispatchSemaphore(value: 0)
        group.next().execute { gate.wait() }
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        let pending = Task { try await transport.connect() }
        try await Task.sleep(nanoseconds: 30_000_000)
        await transport.close()
        gate.signal()
        do { try await pending.value; XCTFail("Expected close to release connect") }
        catch { XCTAssertTrue(error is NIOTransportError) }
        try await listener.close().get()
        await shutdown(group)
    }

    func testCloseReleasesPendingWriteDespiteIgnoredCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        let gate = DispatchSemaphore(value: 0)
        group.next().execute { gate.wait() }
        let pending = Task { try await transport.write(Data("private-payload".utf8)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let closing = Task { await transport.close() }
        do { try await pending.value; XCTFail("Expected close to release write") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        gate.signal()
        await closing.value
        try await listener.close().get()
        await shutdown(group)
    }

    func testOwnedGroupCloseDuringAdmittedConnectWaitsForSubmission() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try server(group: serverGroup, recorder: ServerRecorder())
        let admitted = expectation(description: "connect admitted before submission")
        let closed = expectation(description: "connect waiter released by close")
        let gate = DispatchSemaphore(value: 0)
        let signalLock = NSLock()
        var submissionReleased = false
        let transport = NIOManageSieveTransport(
            endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!),
            eventLoopGroup: nil,
            submissionHook: {
                admitted.fulfill(); gate.wait()
                signalLock.lock(); submissionReleased = true; signalLock.unlock()
            },
            closeHook: { closed.fulfill() },
            shutdownHook: {
                signalLock.lock(); defer { signalLock.unlock() }
                XCTAssertTrue(submissionReleased, "owned group shut down before admitted connect submission")
            }
        )
        let pending = Task { try await transport.connect() }
        await fulfillment(of: [admitted], timeout: 3)
        let closing = Task { await transport.close() }
        await fulfillment(of: [closed], timeout: 3)
        do { _ = try await transport.read(maxBytes: 1); XCTFail("Expected closed state") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        gate.signal()
        do { try await pending.value; XCTFail("Expected close to release connect") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        await closing.value
        try await listener.close().get()
        await shutdown(serverGroup)
    }

    func testOwnedGroupCloseDuringAdmittedWriteWaitsForSubmission() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try server(group: serverGroup, recorder: ServerRecorder())
        let admitted = expectation(description: "write admitted before submission")
        let closed = expectation(description: "write waiter released by close")
        let gate = DispatchSemaphore(value: 0)
        let submissionLock = NSLock()
        var submissionCount = 0
        var submissionReleased = false
        let transport = NIOManageSieveTransport(
            endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!),
            eventLoopGroup: nil,
            submissionHook: {
                submissionLock.lock(); submissionCount += 1
                let isWrite = submissionCount == 2
                submissionLock.unlock()
                if isWrite {
                    admitted.fulfill(); gate.wait()
                    submissionLock.lock(); submissionReleased = true; submissionLock.unlock()
                }
            },
            closeHook: { closed.fulfill() },
            shutdownHook: {
                submissionLock.lock(); defer { submissionLock.unlock() }
                XCTAssertTrue(submissionReleased, "owned group shut down before admitted write submission")
            }
        )
        try await transport.connect()
        let writing = Task { try await transport.write(Data("secret".utf8)) }
        await fulfillment(of: [admitted], timeout: 3)
        let closing = Task { await transport.close() }
        await fulfillment(of: [closed], timeout: 3)
        do { _ = try await transport.read(maxBytes: 1); XCTFail("Expected closed state") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        gate.signal()
        do { try await writing.value; XCTFail("Expected close to release write") }
        catch { XCTAssertEqual(error as? NIOTransportError, .closed) }
        await closing.value
        try await listener.close().get()
        await shutdown(serverGroup)
    }

    func testFloodWithoutReaderClosesWithSanitizedOverflow() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        await waitUntil { recorder.channel != nil }
        let peer = try XCTUnwrap(recorder.channel)
        try? await peer.writeAndFlush(ByteBuffer(bytes: Array(repeating: UInt8(0x5a), count: 128 * 1024))).get()
        await waitUntil { !peer.isActive }
        do { _ = try await transport.read(maxBytes: 1); XCTFail("Expected overflow") }
        catch {
            XCTAssertEqual(error as? NIOTransportError, .inboundOverflow)
            XCTAssertFalse(String(describing: error).contains("ZZZZ"))
        }
        await transport.close()
        try await listener.close().get()
        await shutdown(group)
    }

    private func tlsServer(group: EventLoopGroup, recorder: ServerRecorder, fragmented: Bool = false) throws -> Channel {
        let cert = try NIOSSLCertificate(bytes: Array(tlsFixture("server.der")), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(tlsFixture("server-key.pem")), format: .pem)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key)))
        return try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let fragment = FragmentTLSWrites(enabled: fragmented)
                do {
                    try channel.pipeline.syncOperations.addHandler(fragment)
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(recorder)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.bind(host: "127.0.0.1", port: 0).wait()
    }

    private func startTLSServer(group: EventLoopGroup, fragmented: Bool, maximumTLSVersion: TLSVersion? = nil) throws -> (Channel, ServerRecorder) {
        let cert = try NIOSSLCertificate(bytes: Array(tlsFixture("server.der")), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(tlsFixture("server-key.pem")), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
        configuration.maximumTLSVersion = maximumTLSVersion
        let context = try NIOSSLContext(configuration: configuration)
        let recorder = ServerRecorder(startTLSContext: context, unsolicitedPostTLS: Self.unsolicitedPostTLSCapabilities)
        let listener = try ServerBootstrap(group: group).childChannelInitializer { channel in
            do {
                try channel.pipeline.syncOperations.addHandler(FragmentTLSWrites(enabled: fragmented))
                try channel.pipeline.syncOperations.addHandler(recorder)
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }.bind(host: "127.0.0.1", port: 0).wait()
        return (listener, recorder)
    }

    // Event-loop confined; delayed chunks force separate socket deliveries, not just separate writes.
    final class FragmentTLSWrites: ChannelOutboundHandler, @unchecked Sendable {
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let enabled: Bool
        private var chunks: [(ByteBuffer, EventLoopPromise<Void>?)] = []
        private var context: ChannelHandlerContext?
        private var sending = false
        init(enabled: Bool) { self.enabled = enabled }
        func handlerAdded(context: ChannelHandlerContext) { self.context = context }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            guard enabled else { context.write(data, promise: promise); return }
            var buffer = unwrapOutboundIn(data)
            guard buffer.readableBytes > 0 else { context.write(data, promise: promise); return }
            while buffer.readableBytes > 0 {
                let slice = buffer.readSlice(length: min(17, buffer.readableBytes))!
                chunks.append((slice, buffer.readableBytes == 0 ? promise : nil))
            }
            if !sending { sending = true; sendNext() }
        }
        private func sendNext() {
            guard let context else { return }
            guard !chunks.isEmpty else { sending = false; return }
            let (slice, promise) = chunks.removeFirst()
            context.write(wrapOutboundOut(slice), promise: promise)
            context.flush()
            context.eventLoop.scheduleTask(in: .milliseconds(1)) { self.sendNext() }
        }
    }

    func testTLSUpgradeExistingChannelEncryptedReadWriteAndFragmentedRecords() async throws {
        // Under TLS 1.2 the server's Finished ends the handshake, so the unsolicited capability block is written
        // directly behind the last handshake record; under TLS 1.3 it follows the client's Finished.
        let variants: [(fragmented: Bool, maximumTLSVersion: TLSVersion?)] = [(false, nil), (true, nil), (false, .tlsv12), (true, .tlsv12)]
        for (fragmented, maximumTLSVersion) in variants {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let (listener, recorder) = try startTLSServer(group: group, fragmented: fragmented, maximumTLSVersion: maximumTLSVersion)
            let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group, trustEvaluator: FixtureTLSChainTrustEvaluator())
            try await transport.connect()
            await waitUntil { recorder.channel != nil }
            let peer = try XCTUnwrap(recorder.channel)
            var greeting = Data()
            while !greeting.suffix(4).elementsEqual("OK\r\n".utf8) { greeting.append(try await transport.read(maxBytes: 4096)) }
            XCTAssertEqual(greeting, Data("\"STARTTLS\"\r\nOK\r\n".utf8))
            try await transport.write(Data("STARTTLS\r\n".utf8))
            for byte in "OK\r\n".utf8 { let read = try await transport.read(maxBytes: 1); XCTAssertEqual(read, Data([byte])) }
            try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("source.example.org")]))
            // The re-issued capabilities arrive after the handshake and are readable before the client writes anything.
            let expectedUnsolicited = Data(Self.unsolicitedPostTLSCapabilities.utf8)
            var unsolicited = Data()
            while unsolicited.count < expectedUnsolicited.count { unsolicited.append(try await transport.read(maxBytes: 4096)) }
            XCTAssertEqual(unsolicited, expectedUnsolicited)
            XCTAssertTrue(recorder.bytes.isEmpty, "The unsolicited block must not depend on a client command")
            try await transport.write(Data("encrypted request".utf8))
            await waitUntil { recorder.bytes == Data("encrypted request".utf8) }
            try await peer.writeAndFlush(ByteBuffer(string: "encrypted response")).get()
            var response = Data()
            while response.count < 18 { response.append(try await transport.read(maxBytes: 4096)) }
            XCTAssertEqual(response, Data("encrypted response".utf8))
            await transport.close()
            try await listener.close().get()
            await shutdown(group)
        }
    }

    func testTLSIdentityAndTrustFailuresAreDistinctSanitizedAndPreventWrites() async throws {
        for trust in [true, false] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let recorder = ServerRecorder()
            let listener = try tlsServer(group: group, recorder: recorder)
            let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group, trustEvaluator: FixtureTLSChainTrustEvaluator(trusted: trust))
            try await transport.connect()
            do {
                try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("target.example.net")]))
                XCTFail("Untrusted target must never authenticate")
            } catch { XCTAssertEqual(error as? NIOTransportError, trust ? .tlsIdentityFailed : .tlsTrustFailed) }
            do { try await transport.write(Data("password-secret".utf8)); XCTFail("No writes after failure") }
            catch { XCTAssertFalse(String(describing: error).contains("target.example.net")) }
            XCTAssertTrue(recorder.bytes.isEmpty)
            await transport.close()
            try await listener.close().get()
            await shutdown(group)
        }
    }

    func testProductionTransportUsesSystemTrustNotFixtureTrust() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try tlsServer(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        do {
            try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("source.example.org")]))
            XCTFail("Test CA must not be trusted by production")
        } catch { XCTAssertEqual(error as? NIOTransportError, .tlsTrustFailed) }
        XCTAssertTrue(recorder.bytes.isEmpty)
        await transport.close()
        try await listener.close().get()
        await shutdown(group)
    }

    func testCloseAndCancellationReleaseHandshakeExactlyOnce() async throws {
        for cancel in [false, true] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let recorder = ServerRecorder()
            let listener = try server(group: group, recorder: recorder)
            let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
            try await transport.connect()
            let pending = Task { try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("source.example.org")])) }
            await waitUntil { !recorder.bytes.isEmpty }
            if cancel { pending.cancel() } else { await transport.close() }
            do { try await pending.value; XCTFail("Handshake cannot succeed") }
            catch { XCTAssertTrue(error is NIOTransportError || error is CancellationError) }
            do { try await transport.write(Data("secret".utf8)); XCTFail("No post-failure writes") } catch {}
            await transport.close()
            try await listener.close().get()
            await shutdown(group)
        }
    }

    private actor VerificationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private struct GatedTrustEvaluator: TLSChainTrustEvaluating {
        let gate: VerificationGate
        let entered: XCTestExpectation
        func evaluate(certificateChainDER: [Data]) async throws {
            entered.fulfill()
            await gate.wait()
            try await FixtureTLSChainTrustEvaluator().evaluate(certificateChainDER: certificateChainDER)
        }
    }

    func testCloseAndCancelDuringAsyncTrustReleaseWaiterAndIgnoreLateVerification() async throws {
        for cancel in [false, true] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let recorder = ServerRecorder()
            let listener = try tlsServer(group: group, recorder: recorder)
            let gate = VerificationGate()
            let entered = expectation(description: "asynchronous trust entered")
            let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group, trustEvaluator: GatedTrustEvaluator(gate: gate, entered: entered))
            try await transport.connect()
            let pending = Task { try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("source.example.org")])) }
            await fulfillment(of: [entered], timeout: 3)
            let loopResponsive = try await group.next().submit { true }.get()
            XCTAssertTrue(loopResponsive, "Trust evaluation must not block the event loop")
            do { try await transport.write(Data("premature secret".utf8)); XCTFail("No application writes during verification") }
            catch { XCTAssertEqual(error as? NIOTransportError, .invalidState) }
            if cancel { pending.cancel() } else { await transport.close() }
            do { try await pending.value; XCTFail("Closed handshake must fail") } catch {}
            await gate.release()
            do { try await transport.write(Data("late secret".utf8)); XCTFail("Late trust cannot resurrect transport") } catch {}
            XCTAssertTrue(recorder.bytes.isEmpty)
            await transport.close()
            try await listener.close().get()
            await shutdown(group)
        }
    }

    func testCoalescedOKAndFirstTLSRecordSuffixIsReplayedFromPipelineHead() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ServerRecorder()
        let listener = try server(group: group, recorder: recorder)
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: listener.localAddress!.port!), eventLoopGroup: group)
        try await transport.connect()
        await waitUntil { recorder.channel != nil }
        // A complete TLS fatal handshake_failure alert, coalesced with the plaintext terminal line.
        let bytes = Array("OK\r\n".utf8) + [21, 3, 3, 0, 2, 2, 40]
        try await recorder.channel!.writeAndFlush(ByteBuffer(bytes: bytes)).get()
        for byte in "OK\r\n".utf8 { let read = try await transport.read(maxBytes: 1); XCTAssertEqual(read, Data([byte])) }
        let pending = Task { try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: [.dns("source.example.org")])) }
        let completed = expectation(description: "buffered alert fails handshake without another socket read")
        let observer = Task {
            do { try await pending.value; XCTFail("Expected TLS alert failure") }
            catch { XCTAssertEqual(error as? NIOTransportError, .tlsHandshakeFailed) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
        await transport.close()
        await observer.value
        try await listener.close().get()
        await shutdown(group)
    }
}
