import Foundation
import NIOCore
import NIOPosix

public final class NIOManageSieveTransport: ManageSieveTransport, @unchecked Sendable {
    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    private enum Lifecycle {
        case disconnected
        case connecting
        case connected(Channel)
        case closed
    }

    private let endpoint: Endpoint
    private let group: any EventLoopGroup
    private let ownsGroup: Bool
    private let submissionHook: (() -> Void)?
    private let closeHook: (() -> Void)?
    private let shutdownHook: (() -> Void)?
    private let lock = NSLock()
    private var activeSubmissions = 0
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    private var terminalError: NIOTransportError?
    private static let maximumBufferedInboundBytes = 64 * 1024
    private var lifecycle: Lifecycle = .disconnected
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var readWaiters: [(Int, CheckedContinuation<Data, Error>)] = []
    private var writeWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var received = Data()
    private var eof = false

    public convenience init(endpoint: Endpoint, eventLoopGroup: (any EventLoopGroup)? = nil) {
        self.init(endpoint: endpoint, eventLoopGroup: eventLoopGroup, submissionHook: nil, closeHook: nil, shutdownHook: nil)
    }

    // The hook exposes admission to deterministic loopback race tests; production never supplies it.
    internal init(endpoint: Endpoint, eventLoopGroup: (any EventLoopGroup)?, submissionHook: (() -> Void)?, closeHook: (() -> Void)? = nil, shutdownHook: (() -> Void)? = nil) {
        self.endpoint = endpoint
        self.ownsGroup = eventLoopGroup == nil
        self.group = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.submissionHook = submissionHook
        self.closeHook = closeHook
        self.shutdownHook = shutdownHook
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard case .disconnected = lifecycle else {
                lock.unlock()
                continuation.resume(throwing: NIOTransportError.invalidState)
                return
            }
            lifecycle = .connecting
            connectWaiter = continuation
            activeSubmissions += 1
            lock.unlock()

            submissionHook?()
            defer { finishSubmission() }
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in channel.pipeline.addHandler(InboundHandler(owner: self)) }
            let future: EventLoopFuture<Channel> = bootstrap.connect(host: endpoint.host, port: endpoint.port)
            future.whenComplete { result in self.finishConnect(result) }
        }
    }

    private func finishConnect(_ result: Result<Channel, Error>) {
        lock.lock()
        let waiter = connectWaiter
        connectWaiter = nil
        if case .connecting = lifecycle {
            switch result {
            case .success(let channel): lifecycle = .connected(channel)
            case .failure: lifecycle = .disconnected
            }
            let ready = drainReads()
            lock.unlock()
            for (readWaiter, data) in ready { readWaiter.resume(returning: data) }
            switch result {
            case .success: waiter?.resume()
            case .failure: waiter?.resume(throwing: NIOTransportError.connectionFailed)
            }
        } else {
            lock.unlock()
            if case .success(let channel) = result { channel.close(promise: nil) }
        }
    }

    public func read(maxBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard maxBytes > 0 else {
                lock.unlock()
                continuation.resume(throwing: NIOTransportError.invalidReadSize)
                return
            }
            guard terminalError == nil, case .connected = lifecycle else {
                let error: NIOTransportError = terminalError ?? (isClosed ? .closed : .invalidState)
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            readWaiters.append((maxBytes, continuation))
            let ready = drainReads()
            lock.unlock()
            for (waiter, data) in ready { waiter.resume(returning: data) }
        }
    }

    // Called only while holding lock; suffixes remain buffered for later readers.
    private func drainReads() -> [(CheckedContinuation<Data, Error>, Data)] {
        var ready: [(CheckedContinuation<Data, Error>, Data)] = []
        while !readWaiters.isEmpty && (!received.isEmpty || eof) {
            let (limit, waiter) = readWaiters.removeFirst()
            let count = min(limit, received.count)
            let data = Data(received.prefix(count))
            received.removeFirst(count)
            ready.append((waiter, data))
        }
        return ready
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard terminalError == nil, case .connected(let channel) = lifecycle else {
                let error: NIOTransportError = terminalError ?? (isClosed ? .closed : .invalidState)
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            let id = UUID()
            writeWaiters[id] = continuation
            activeSubmissions += 1
            lock.unlock()
            submissionHook?()
            defer { finishSubmission() }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let future: EventLoopFuture<Void> = channel.writeAndFlush(buffer)
            future.whenComplete { result in
                self.lock.lock()
                let waiter = self.writeWaiters.removeValue(forKey: id)
                self.lock.unlock()
                switch result {
                case .success: waiter?.resume()
                case .failure: waiter?.resume(throwing: NIOTransportError.writeFailed)
                }
            }
        }
    }

    private func finishSubmission() {
        lock.lock()
        activeSubmissions -= 1
        let waiter = activeSubmissions == 0 ? submissionWaiter : nil
        if waiter != nil { submissionWaiter = nil }
        lock.unlock()
        waiter?.resume()
    }

    private func awaitSubmissions() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activeSubmissions == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                submissionWaiter = continuation
                lock.unlock()
            }
        }
    }

    public func upgradeToTLS(identity: ManageSieveTLSIdentityRequest) async throws {
        throw NIOTransportError.tlsUnsupported
    }

    public func close() async {
        guard let channel = beginClose() else { return }
        await awaitSubmissions()
        if let channel { _ = try? await channel.close().get() }
        if ownsGroup {
            shutdownHook?()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { _ in continuation.resume() }
            }
        }
    }

    // The outer optional distinguishes an already closed transport from a first close without a channel.
    private func beginClose() -> Channel?? {
        lock.lock()
        guard !isClosed else { lock.unlock(); return nil }
        let channel: Channel?
        if case .connected(let current) = lifecycle { channel = current } else { channel = nil }
        lifecycle = .closed
        let connect = connectWaiter
        connectWaiter = nil
        let reads = readWaiters
        readWaiters.removeAll()
        let writes = Array(writeWaiters.values)
        writeWaiters.removeAll()
        lock.unlock()
        let failure = terminalError ?? .closed
        connect?.resume(throwing: failure)
        for (_, waiter) in reads { waiter.resume(throwing: failure) }
        for waiter in writes { waiter.resume(throwing: failure) }
        closeHook?()
        return .some(channel)
    }

    private var isClosed: Bool {
        if case .closed = lifecycle { return true }
        return false
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        guard terminalError == nil else { lock.unlock(); return }
        received.append(data)
        let ready = drainReads()
        let overflow = received.count > Self.maximumBufferedInboundBytes
        if overflow {
            terminalError = .inboundOverflow
            received.removeAll()
        }
        lock.unlock()
        for (waiter, data) in ready { waiter.resume(returning: data) }
        if overflow { Task { await self.close() } }
    }

    private func endOfStream() {
        lock.lock()
        guard terminalError == nil else { lock.unlock(); return }
        eof = true
        let ready = drainReads()
        lock.unlock()
        for (waiter, data) in ready { waiter.resume(returning: data) }
    }

    private final class InboundHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let owner: NIOManageSieveTransport
        init(owner: NIOManageSieveTransport) { self.owner = owner }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            owner.receive(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
        func channelInactive(context: ChannelHandlerContext) {
            owner.endOfStream()
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }
    }
}
