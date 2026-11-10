import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import SievePilotCore

final class NIOManageSieveTransportTests: XCTestCase {
    private final class ServerRecorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let lock = NSLock()
        private var storedChannel: Channel?
        private var storedBytes = Data()
        var channel: Channel? { lock.lock(); defer { lock.unlock() }; return storedChannel }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return storedBytes }
        func channelActive(context: ChannelHandlerContext) {
            lock.lock(); storedChannel = context.channel; lock.unlock()
            context.fireChannelActive()
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            lock.lock(); storedBytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? []); lock.unlock()
        }
    }

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

    func testTLSIsUnsupportedAndCannotEnableAuthentication() async throws {
        let transport = NIOManageSieveTransport(endpoint: .init(host: "127.0.0.1", port: 4190))
        do {
            try await transport.upgradeToTLS(identity: .init(referenceIdentifiers: ["example.com"]))
            XCTFail("TLS cannot succeed in Task 1")
        } catch {
            XCTAssertEqual(error as? NIOTransportError, .tlsUnsupported)
        }
        await transport.close()
    }
}
