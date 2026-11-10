import Foundation

public enum ManageSieveClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case startTLS
    case encryptedReady
    case closed
}

public enum ManageSieveClientError: Error, Equatable, Sendable {
    case invalidState
    case invalidIdentity
    case missingStartTLS
    case unexpectedEOF
    case parse
    case transport
    case tls
    case timeout
    case serverNo
    case serverBye
}

public actor ManageSieveClient {
    private let transport: any ManageSieveTransport
    private let clock: any ManageSieveClock
    private let timeoutPolicy: ManageSieveTimeoutPolicy
    private let limits: ManageSieveLimits
    private let logger: any ManageSieveLogger
    private var admittedOperation = false
    public private(set) var capabilities: ManageSieveCapabilities?
    public private(set) var state: ManageSieveClientState = .disconnected

    public init(
        transport: any ManageSieveTransport,
        clock: any ManageSieveClock,
        timeoutPolicy: ManageSieveTimeoutPolicy,
        limits: ManageSieveLimits,
        logger: any ManageSieveLogger
    ) {
        self.transport = transport
        self.clock = clock
        self.timeoutPolicy = timeoutPolicy
        self.limits = limits
        self.logger = logger
    }

    public func connectAndStartTLS(
        identity: ManageSieveTLSIdentityRequest,
        timeout: Duration? = nil
    ) async throws -> ManageSieveCapabilities {
        guard state == .disconnected, !admittedOperation else { throw ManageSieveClientError.invalidState }
        guard !identity.referenceIdentifiers.isEmpty,
              identity.referenceIdentifiers.allSatisfy({ !$0.isEmpty }) else {
            throw ManageSieveClientError.invalidIdentity
        }
        admittedOperation = true
        state = .connecting
        do {
            let result = try await withTimeout(timeout ?? timeoutPolicy.connect + timeoutPolicy.startTLS) {
                try await self.performHandshake(identity: identity)
            }
            admittedOperation = false
            return result
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    public func capability() async throws -> ManageSieveCapabilities {
        guard state == .encryptedReady, !admittedOperation, capabilities != nil else {
            throw ManageSieveClientError.invalidState
        }
        admittedOperation = true
        do {
            let replacement = try await withTimeout(timeoutPolicy.command) {
                try await self.refreshCapabilities()
            }
            try ensureOpen()
            self.capabilities = replacement
            admittedOperation = false
            return replacement
        } catch let error as ManageSieveClientError where error == .serverNo {
            admittedOperation = false
            throw error
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    public func close() async {
        guard state != .closed else { return }
        state = .closed
        capabilities = nil
        await transport.close()
        logger.record(.closed)
    }

    private func performHandshake(identity: ManageSieveTLSIdentityRequest) async throws -> ManageSieveCapabilities {
        do { try await transport.connect() } catch { throw ManageSieveClientError.transport }
        try ensureOpen()
        logger.record(.connected)
        let greeting = try await readResponse()
        try requireOK(greeting)
        do {
            let preTLS = try interpret(greeting, origin: .preTLSGreeting)
            guard preTLS.containsCapability("STARTTLS") else { throw ManageSieveClientError.missingStartTLS }
        }
        state = .startTLS
        try await send("STARTTLS\r\n")
        let response = try await readResponse()
        try requireOK(response)
        do { try await transport.upgradeToTLS(identity: identity) } catch {
            throw ManageSieveClientError.tls
        }
        // No greeting-derived fields survive the upgrade or become authoritative.
        capabilities = nil
        try ensureOpen()
        logger.record(.encrypted)
        let secure = try await refreshCapabilities()
        try ensureOpen()
        capabilities = secure
        state = .encryptedReady
        return secure
    }

    private func refreshCapabilities() async throws -> ManageSieveCapabilities {
        try await send("CAPABILITY\r\n")
        let response = try await readResponse()
        try requireOK(response)
        return try interpret(response, origin: .postTLSCapability)
    }

    private func send(_ command: String) async throws {
        try ensureOpen()
        do { try await transport.write(Data(command.utf8)) } catch {
            throw ManageSieveClientError.transport
        }
        try ensureOpen()
    }

    private func readResponse() async throws -> ManageSieveCommandResponse {
        var parser = ManageSieveResponseParser(limits: limits)
        var lines: [ManageSieveWireLine] = []
        while true {
            try ensureOpen()
            let bytes: Data
            do { bytes = try await transport.read(maxBytes: 4096) } catch {
                throw ManageSieveClientError.transport
            }
            try ensureOpen()
            guard !bytes.isEmpty else {
                do { try parser.finish() } catch { throw ManageSieveClientError.parse }
                throw ManageSieveClientError.unexpectedEOF
            }
            do { lines.append(contentsOf: try parser.feed(bytes)) } catch {
                throw ManageSieveClientError.parse
            }
            if lines.contains(where: { line in
                guard case let .atom(word)? = line.tokens.first else { return false }
                return ["OK", "NO", "BYE"].contains(word.uppercased())
            }) {
                guard lines.last.map({ line in
                    guard case let .atom(word)? = line.tokens.first else { return false }
                    return ["OK", "NO", "BYE"].contains(word.uppercased())
                }) == true else { throw ManageSieveClientError.parse }
                do {
                    try parser.finish()
                    return try ManageSieveCommandResponse(lines: lines)
                } catch { throw ManageSieveClientError.parse }
            }
        }
    }

    private func requireOK(_ response: ManageSieveCommandResponse) throws {
        switch response.status.status {
        case .ok: break
        case .no: throw ManageSieveClientError.serverNo
        case .bye: throw ManageSieveClientError.serverBye
        }
    }

    private func interpret(_ response: ManageSieveCommandResponse, origin: ManageSieveCapabilityOrigin) throws -> ManageSieveCapabilities {
        do { return try ManageSieveCapabilities(response: response, origin: origin) } catch {
            throw ManageSieveClientError.parse
        }
    }

    private func ensureOpen() throws {
        try Task.checkCancellation()
        guard state != .closed else { throw ManageSieveClientError.invalidState }
    }

    private func closeAfterFailure() async {
        await close()
        admittedOperation = false
    }

    private func sanitized(_ error: Error) -> ManageSieveClientError {
        if let clientError = error as? ManageSieveClientError { return clientError }
        if error is CancellationError { return .timeout }
        return .transport
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [clock] in
                try await clock.sleep(for: duration)
                throw ManageSieveClientError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ManageSieveClientError.timeout }
            return result
        }
    }
}
