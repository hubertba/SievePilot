import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import X509

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

    private let trustEvaluator: any TLSChainTrustEvaluating
    private var inboundHandler: InboundHandler?
    private var tlsStarted = false
    private var tlsReady = false
    private var tlsVerified = false
    private var handshakeWaiter: CheckedContinuation<Void, Error>?
    private var verificationPromise: EventLoopPromise<NIOSSLVerificationResult>?
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
    internal init(endpoint: Endpoint, eventLoopGroup: (any EventLoopGroup)?, trustEvaluator: any TLSChainTrustEvaluating = SecurityTLSChainTrustEvaluator(), submissionHook: (() -> Void)? = nil, closeHook: (() -> Void)? = nil, shutdownHook: (() -> Void)? = nil) {
        self.trustEvaluator = trustEvaluator
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
                .channelInitializer { channel in
                    let handler = InboundHandler(owner: self)
                    self.lock.lock()
                    guard !self.isClosed else {
                        self.lock.unlock()
                        return channel.eventLoop.makeFailedFuture(NIOTransportError.closed)
                    }
                    self.inboundHandler = handler
                    self.lock.unlock()
                    return channel.pipeline.addHandler(handler)
                }
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
            case .failure:
                lifecycle = .disconnected
                inboundHandler = nil
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
            guard terminalError == nil, (!tlsStarted || tlsReady), case .connected = lifecycle else {
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
            guard terminalError == nil, (!tlsStarted || tlsReady), case .connected(let channel) = lifecycle else {
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
            channel.eventLoop.execute {
                self.lock.lock()
                guard self.terminalError == nil, !self.isClosed, (!self.tlsStarted || self.tlsReady) else {
                    let waiter = self.writeWaiters.removeValue(forKey: id)
                    let failure = self.terminalError ?? .closed
                    self.lock.unlock()
                    waiter?.resume(throwing: failure)
                    return
                }
                self.lock.unlock()
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
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard terminalError == nil, !tlsStarted, readWaiters.isEmpty,
                      case .connected(let channel) = lifecycle, inboundHandler != nil else {
                    let error = terminalError ?? (isClosed ? .closed : .invalidState)
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                tlsStarted = true
                handshakeWaiter = continuation
                activeSubmissions += 1
                lock.unlock()
                defer { finishSubmission() }
                do {
                    var configuration = TLSConfiguration.makeClientConfiguration()
                    // Keep peer verification enabled, but replace NIO's separate target/IP hostname
                    // check with typed service identifiers in our custom verifier.
                    configuration.certificateVerification = .noHostnameVerification
                    let context = try NIOSSLContext(configuration: configuration)
                    channel.eventLoop.execute {
                        self.installTLS(context: context, identity: identity, channel: channel)
                    }
                } catch { failTLS(.tlsHandshakeFailed) }
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    // All pipeline mutation, unread-suffix extraction, and replay run in one event-loop turn.
    private func installTLS(context: NIOSSLContext, identity: ManageSieveTLSIdentityRequest, channel: Channel) {
        channel.eventLoop.preconditionInEventLoop()
        do {
            guard let options = channel.syncOptions else { throw NIOTransportError.invalidState }
            let oldAutoRead = try options.getOption(ChannelOptions.autoRead)
            try options.setOption(ChannelOptions.autoRead, value: false)
            lock.lock()
            guard terminalError == nil, !isClosed, handshakeWaiter != nil, let inbound = inboundHandler else {
                lock.unlock()
                throw NIOTransportError.closed
            }
            let suffix = received
            received.removeAll()
            lock.unlock()
            inbound.preTLSAutoRead = oldAutoRead
            // SNI is routing metadata only; it is never added to the reference identifiers.
            let hostname = (try? SocketAddress(ipAddress: endpoint.host, port: endpoint.port)) == nil ? endpoint.host : nil
            let handler = try NIOSSLClientHandler(context: context, serverHostname: hostname) { chain, promise in
                self.verify(chain: chain, identity: identity, promise: promise)
            }
            try channel.pipeline.syncOperations.addHandler(handler, position: .before(inbound))
            if !suffix.isEmpty {
                var buffer = channel.allocator.buffer(capacity: suffix.count)
                buffer.writeBytes(suffix)
                channel.pipeline.fireChannelRead(buffer)
                channel.pipeline.fireChannelReadComplete()
            }
            // NIOSSL drives subsequent manual reads until Finished restores the previous mode.
            channel.read()
        } catch { failTLS(.tlsHandshakeFailed) }
    }

    private func verify(chain: [NIOSSLCertificate], identity: ManageSieveTLSIdentityRequest, promise: EventLoopPromise<NIOSSLVerificationResult>) {
        lock.lock()
        guard !isClosed, terminalError == nil, handshakeWaiter != nil else {
            lock.unlock()
            promise.succeed(.failed)
            return
        }
        verificationPromise = promise
        lock.unlock()
        // Security trust and X509 parsing must not run on the channel's event loop.
        Task.detached {
            let result: Result<Void, NIOTransportError>
            do {
                let der: [Data]
                do { der = try chain.map { Data(try $0.toDERBytes()) } }
                catch { throw NIOTransportError.tlsTrustFailed }
                do { try await self.trustEvaluator.evaluate(certificateChainDER: der) }
                catch { throw NIOTransportError.tlsTrustFailed }
                do {
                    let certificates = try der.map { try Certificate(derEncoded: Array($0)) }
                    try ManageSieveTLSIdentityValidator().validate(certificateChain: certificates, identifiers: identity.referenceIdentifiers)
                } catch { throw NIOTransportError.tlsIdentityFailed }
                result = .success(())
            } catch { result = .failure(error as? NIOTransportError ?? .tlsTrustFailed) }
            self.finishVerification(result)
        }
    }

    private func finishVerification(_ result: Result<Void, NIOTransportError>) {
        lock.lock()
        let promise = verificationPromise
        verificationPromise = nil
        guard let promise else { lock.unlock(); return }
        let active = !isClosed && terminalError == nil && handshakeWaiter != nil
        if active, case .success = result { tlsVerified = true }
        if active, case .failure(let failure) = result { terminalError = failure }
        lock.unlock()
        if active, case .success = result { promise.succeed(.certificateVerified) }
        else {
            promise.succeed(.failed)
            if active, case .failure(let failure) = result { failTLS(failure) }
        }
    }

    private func handshakeCompleted(channel: Channel, autoRead: Bool) {
        channel.setOption(ChannelOptions.autoRead, value: autoRead).whenComplete { result in
            self.lock.lock()
            guard self.terminalError == nil, !self.isClosed, self.tlsVerified, case .success = result else {
                self.lock.unlock()
                self.failTLS(.tlsHandshakeFailed)
                return
            }
            self.tlsReady = true
            let waiter = self.handshakeWaiter
            self.handshakeWaiter = nil
            self.lock.unlock()
            waiter?.resume()
        }
    }

    private func failTLS(_ error: NIOTransportError) {
        lock.lock()
        if !isClosed, terminalError == nil { terminalError = error }
        let failure = terminalError ?? .closed
        let waiter = handshakeWaiter
        handshakeWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: failure)
        Task { await self.close() }
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
        inboundHandler = nil
        received.removeAll()
        let connect = connectWaiter
        connectWaiter = nil
        let handshake = handshakeWaiter
        handshakeWaiter = nil
        let verification = verificationPromise
        verificationPromise = nil
        let reads = readWaiters
        readWaiters.removeAll()
        let writes = Array(writeWaiters.values)
        writeWaiters.removeAll()
        lock.unlock()
        let failure = terminalError ?? .closed
        verification?.succeed(.failed)
        handshake?.resume(throwing: failure)
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
        if tlsStarted && !tlsReady && !isClosed {
            lock.unlock()
            failTLS(.tlsHandshakeFailed)
            return
        }
        guard terminalError == nil else { lock.unlock(); return }
        eof = true
        let ready = drainReads()
        lock.unlock()
        for (waiter, data) in ready { waiter.resume(returning: data) }
    }

    private final class InboundHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let owner: NIOManageSieveTransport
        // Event-loop confined; captured before insertion and restored only after verification + Finished.
        var preTLSAutoRead: Bool?
        init(owner: NIOManageSieveTransport) { self.owner = owner }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            owner.receive(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
        func channelInactive(context: ChannelHandlerContext) {
            owner.endOfStream()
            context.fireChannelInactive()
        }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case .handshakeCompleted = event as? TLSUserEvent, let autoRead = preTLSAutoRead {
                owner.handshakeCompleted(channel: context.channel, autoRead: autoRead)
            }
            context.fireUserInboundEventTriggered(event)
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            owner.failTLS(.tlsHandshakeFailed)
            context.close(promise: nil)
        }
    }
}
