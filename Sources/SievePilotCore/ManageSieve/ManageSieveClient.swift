import Foundation

public enum ManageSieveClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case startTLS
    case encryptedReady
    case authenticated
    case closed
}

public enum ManageSieveClientError: Error, Equatable, Sendable {
    case invalidState
    case invalidIdentity
    case invalidCredentials
    case unsupportedMechanism
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

    public func authenticatePlain(username: String, password: String, timeout: Duration? = nil) async throws {
        try admitAuthentication("PLAIN")
        guard !username.contains("\0"), !password.contains("\0") else {
            throw ManageSieveClientError.invalidCredentials
        }
        admittedOperation = true
        logger.record(.authenticationStarted(mechanism: "PLAIN"))
        var accepted = false
        do {
            try await withTimeout(timeout ?? timeoutPolicy.authentication) {
                var payload = ManageSieveAuthentication.plain(username: username, password: password)
                defer { ManageSieveAuthentication.wipe(&payload) }
                var command = Data("AUTHENTICATE \"PLAIN\" ".utf8)
                command.append(ManageSieveAuthentication.quoted(payload))
                command.append(contentsOf: [0x0d, 0x0a])
                defer { ManageSieveAuthentication.wipe(&command) }
                try await self.sendBytes(command)
                let response = try await self.readResponse()
                guard response.dataLines.isEmpty else { throw ManageSieveClientError.parse }
                try self.requireOK(response)
            }
            accepted = true
            try await finishAuthentication(timeout: timeout)
        } catch let error as ManageSieveClientError where error == .serverNo && !accepted && state == .encryptedReady {
            admittedOperation = false
            logger.record(.authenticationRejected)
            throw error
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    public func authenticateLogin(username: String, password: String, timeout: Duration? = nil) async throws {
        try admitAuthentication("LOGIN")
        guard username.count < 64,
              !username.contains("\0"), !username.contains("\r"), !username.contains("\n"),
              !password.contains("\0"), !password.contains("\r"), !password.contains("\n") else {
            throw ManageSieveClientError.invalidCredentials
        }
        admittedOperation = true
        logger.record(.authenticationStarted(mechanism: "LOGIN"))
        var accepted = false
        do {
            try await withTimeout(timeout ?? timeoutPolicy.authentication) {
                try await self.send("AUTHENTICATE \"LOGIN\"\r\n")
                var parser = ManageSieveResponseParser(limits: self.limits)
                var pending: [ManageSieveWireLine] = []
                for value in [username, password] {
                    let line = try await self.readAuthenticationLine(parser: &parser, pending: &pending)
                    if case let .atom(word)? = line.tokens.first,
                       ["OK", "NO", "BYE"].contains(word.uppercased()) {
                        guard pending.isEmpty else { throw ManageSieveClientError.parse }
                        do { try parser.finish() } catch { throw ManageSieveClientError.parse }
                    }
                    try self.requireChallenge(line)
                    if pending.contains(where: { line in
                        if case let .atom(word)? = line.tokens.first {
                            return ["OK", "NO", "BYE"].contains(word.uppercased())
                        }
                        return false
                    }) { throw ManageSieveClientError.parse }
                    var encoded = ManageSieveAuthentication.login(value)
                    defer { ManageSieveAuthentication.wipe(&encoded) }
                    var command = ManageSieveAuthentication.quoted(encoded)
                    command.append(contentsOf: [0x0d, 0x0a])
                    defer { ManageSieveAuthentication.wipe(&command) }
                    try await self.sendBytes(command)
                }
                let terminal = try await self.readAuthenticationLine(parser: &parser, pending: &pending)
                guard pending.isEmpty else { throw ManageSieveClientError.parse }
                do { try parser.finish() } catch { throw ManageSieveClientError.parse }
                let status: ManageSieveStatusResponse
                do { status = try ManageSieveStatusResponse(line: terminal) }
                catch { throw ManageSieveClientError.parse }
                try self.requireStatus(status.status)
            }
            accepted = true
            try await finishAuthentication(timeout: timeout)
        } catch let error as ManageSieveClientError where error == .serverNo && !accepted && state == .encryptedReady {
            admittedOperation = false
            logger.record(.authenticationRejected)
            throw error
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    private func admitAuthentication(_ mechanism: String) throws {
        guard state == .encryptedReady, !admittedOperation, let capabilities,
              capabilities.isAuthoritative else { throw ManageSieveClientError.invalidState }
        guard capabilities.supportsSASLMechanism(mechanism) else {
            throw ManageSieveClientError.unsupportedMechanism
        }
    }

    private func finishAuthentication(timeout: Duration?) async throws {
        let replacement = try await withTimeout(timeout ?? timeoutPolicy.authentication) {
            try await self.refreshCapabilities()
        }
        try ensureOpen()
        capabilities = replacement
        state = .authenticated
        admittedOperation = false
        logger.record(.authenticated)
    }

    private func readAuthenticationLine(
        parser: inout ManageSieveResponseParser,
        pending: inout [ManageSieveWireLine]
    ) async throws -> ManageSieveWireLine {
        while pending.isEmpty {
            try ensureOpen()
            let bytes: Data
            do { bytes = try await transport.read(maxBytes: 4096) }
            catch { throw ManageSieveClientError.transport }
            try ensureOpen()
            guard !bytes.isEmpty else { throw ManageSieveClientError.unexpectedEOF }
            do { pending = try parser.feed(bytes) }
            catch { throw ManageSieveClientError.parse }
        }
        return pending.removeFirst()
    }

    nonisolated private func requireChallenge(_ line: ManageSieveWireLine) throws {
        if let first = line.tokens.first, case let .atom(word) = first,
           ["OK", "NO", "BYE"].contains(word.uppercased()) {
            let status: ManageSieveStatusResponse
            do { status = try ManageSieveStatusResponse(line: line) }
            catch { throw ManageSieveClientError.parse }
            try requireStatus(status.status)
            throw ManageSieveClientError.parse
        }
        guard line.tokens.count == 1, case let .string(value) = line.tokens[0],
              ManageSieveAuthentication.isBase64Challenge(value) else {
            throw ManageSieveClientError.parse
        }
    }

    nonisolated private func requireStatus(_ status: ManageSieveStatus) throws {
        switch status {
        case .ok: break
        case .no: throw ManageSieveClientError.serverNo
        case .bye: throw ManageSieveClientError.serverBye
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
        guard response.dataLines.isEmpty else { throw ManageSieveClientError.parse }
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
        try await sendBytes(Data(command.utf8))
    }

    private func sendBytes(_ bytes: Data) async throws {
        try ensureOpen()
        do { try await transport.write(bytes) } catch {
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

    nonisolated private func requireOK(_ response: ManageSieveCommandResponse) throws {
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

    private func closeOnTimeout() {
        guard state != .closed else { return }
        state = .closed
        capabilities = nil
        let transport = self.transport
        let logger = self.logger
        // Start closure before reporting the timeout; never wait for a stalled transport operation.
        Task {
            await transport.close()
            logger.record(.closed)
        }
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
        let gate = ManageSieveTimeoutGate()
        let operationTask = Task { try await operation() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [clock] in
                    do { try await clock.sleep(for: duration) } catch {
                        if Task.isCancelled { return }
                    }
                    guard !Task.isCancelled, await gate.claim() else { return }
                    closeOnTimeout()
                    operationTask.cancel()
                    continuation.resume(throwing: ManageSieveClientError.timeout)
                }
                Task {
                    let result = await operationTask.result
                    guard await gate.claim() else { return }
                    timeoutTask.cancel()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            operationTask.cancel()
        }
    }
}

private actor ManageSieveTimeoutGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
