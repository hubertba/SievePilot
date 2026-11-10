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
    case operationInProgress
    case cancelled
    case invalidIdentity
    case invalidCredentials
    case invalidScriptName
    case invalidScript
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
    private var admittedOperation: ManageSieveOperationAdmission?
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
        try checkAdmission()
        guard state == .disconnected else { throw ManageSieveClientError.invalidState }
        guard !identity.referenceIdentifiers.isEmpty,
              identity.referenceIdentifiers.allSatisfy({ !$0.isEmpty }) else {
            throw ManageSieveClientError.invalidIdentity
        }
        admittedOperation = ManageSieveOperationAdmission()
        state = .connecting
        do {
            let result = try await withTimeout(timeout ?? timeoutPolicy.connect + timeoutPolicy.startTLS) {
                try await self.performHandshake(identity: identity)
            }
            admittedOperation = nil
            return result
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    public func capability(timeout: Duration? = nil) async throws -> ManageSieveCapabilities {
        try checkAdmission()
        guard (state == .encryptedReady || state == .authenticated), capabilities != nil else {
            throw ManageSieveClientError.invalidState
        }
        admittedOperation = ManageSieveOperationAdmission()
        do {
            let replacement = try await withTimeout(timeout ?? timeoutPolicy.command) {
                try await self.refreshCapabilities()
            }
            try ensureOpen()
            self.capabilities = replacement
            admittedOperation = nil
            return replacement
        } catch let error as ManageSieveClientError where error == .serverNo {
            admittedOperation = nil
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
        admittedOperation = ManageSieveOperationAdmission()
        logger.record(.authenticationStarted(mechanism: "PLAIN"))
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
                try await self.finishAuthentication()
            }
            admittedOperation = nil
        } catch let error as ManageSieveClientError where error == .serverNo && state == .encryptedReady {
            admittedOperation = nil
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
        admittedOperation = ManageSieveOperationAdmission()
        logger.record(.authenticationStarted(mechanism: "LOGIN"))
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
                try await self.finishAuthentication()
            }
            admittedOperation = nil
        } catch let error as ManageSieveClientError where error == .serverNo && state == .encryptedReady {
            admittedOperation = nil
            logger.record(.authenticationRejected)
            throw error
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    private func admitAuthentication(_ mechanism: String) throws {
        try checkAdmission()
        guard state == .encryptedReady, let capabilities,
              capabilities.isAuthoritative else { throw ManageSieveClientError.invalidState }
        guard capabilities.supportsSASLMechanism(mechanism) else {
            throw ManageSieveClientError.unsupportedMechanism
        }
    }

    private func finishAuthentication() async throws {
        do {
            let replacement = try await refreshCapabilities()
            try ensureOpen()
            capabilities = replacement
            state = .authenticated
            logger.record(.authenticated)
        } catch {
            await close()
            throw sanitized(error)
        }
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

    public func listScripts(timeout: Duration? = nil) async throws -> [ManageSieveScriptEntry] {
        try await scriptOperation(timeout: timeout, command: Data("LISTSCRIPTS\r\n".utf8)) { response in
            var seen = Set<String>()
            var activeCount = 0
            var entries: [ManageSieveScriptEntry] = []
            for line in response.dataLines {
                guard (1...2).contains(line.tokens.count),
                      case let .string(bytes) = line.tokens[0],
                      let name = String(data: bytes, encoding: .utf8),
                      !name.isEmpty, !bytes.contains(where: { $0 == 0 || $0 == 0x0d || $0 == 0x0a }),
                      seen.insert(name).inserted else { throw ManageSieveClientError.parse }
                let active = line.tokens.count == 2
                if active {
                    guard case let .atom(marker) = line.tokens[1], marker.uppercased() == "ACTIVE" else {
                        throw ManageSieveClientError.parse
                    }
                    activeCount += 1
                    guard activeCount <= 1 else { throw ManageSieveClientError.parse }
                }
                entries.append(ManageSieveScriptEntry(name: name, isActive: active))
            }
            return entries
        }
    }

    public func getScript(name: String, timeout: Duration? = nil) async throws -> Data {
        let encoded = try scriptName(name)
        return try await scriptOperation(timeout: timeout, command: command("GETSCRIPT ", encoded)) { response in
            guard response.dataLines.count == 1,
                  case let .string(script) = response.dataLines[0].tokens.first,
                  response.dataLines[0].tokens.count == 1 else { throw ManageSieveClientError.parse }
            return script
        }
    }

    public func checkScript(_ script: Data, timeout: Duration? = nil) async throws -> ManageSieveCommandResult {
        try validateScript(script)
        return try await scriptOperation(timeout: timeout, command: literalCommand("CHECKSCRIPT ", script: script)) { response in
            try self.emptyResult(response)
        }
    }

    public func putScript(name: String, script: Data, timeout: Duration? = nil) async throws -> ManageSieveCommandResult {
        let encoded = try scriptName(name)
        try validateScript(script)
        var prefix = Data("PUTSCRIPT ".utf8)
        prefix.append(encoded)
        prefix.append(0x20)
        return try await scriptOperation(timeout: timeout, command: literalCommand(prefix, script: script)) { response in
            try self.emptyResult(response)
        }
    }

    public func setActive(name: String, timeout: Duration? = nil) async throws {
        let encoded = try scriptName(name, allowEmpty: true)
        _ = try await scriptOperation(timeout: timeout, command: command("SETACTIVE ", encoded)) { response in
            try self.emptyResult(response)
        }
    }

    public func deleteScript(name: String, timeout: Duration? = nil) async throws {
        let encoded = try scriptName(name)
        _ = try await scriptOperation(timeout: timeout, command: command("DELETESCRIPT ", encoded)) { response in
            try self.emptyResult(response)
        }
    }

    public func logout(timeout: Duration? = nil) async throws {
        try checkAdmission()
        guard state == .authenticated else { throw ManageSieveClientError.invalidState }
        admittedOperation = ManageSieveOperationAdmission()
        do {
            try await withTimeout(timeout ?? timeoutPolicy.command) {
                try await self.send("LOGOUT\r\n")
                let response = try await self.readResponse()
                guard response.dataLines.isEmpty else { throw ManageSieveClientError.parse }
                guard response.status.status != .no else { throw ManageSieveClientError.serverNo }
            }
            await closeAfterFailure()
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    private func scriptName(_ name: String, allowEmpty: Bool = false) throws -> Data {
        try checkAdmission()
        guard state == .authenticated else { throw ManageSieveClientError.invalidState }
        return try ManageSieveCommandEncoding.name(name, allowEmpty: allowEmpty, maximumLiteralLength: limits.maximumLiteralLength)
    }

    private func validateScript(_ script: Data) throws {
        try checkAdmission()
        guard state == .authenticated else { throw ManageSieveClientError.invalidState }
        guard !script.isEmpty, script.count <= min(limits.maximumLiteralLength, 10 * 1024 * 1024),
              UInt32(exactly: script.count) != nil else { throw ManageSieveClientError.invalidScript }
    }

    private func command(_ prefix: String, _ name: Data) -> Data {
        var bytes = Data(prefix.utf8)
        bytes.append(name)
        bytes.append(contentsOf: [0x0d, 0x0a])
        return bytes
    }

    private func literalCommand(_ prefix: String, script: Data) -> Data {
        literalCommand(Data(prefix.utf8), script: script)
    }

    private func literalCommand(_ prefix: Data, script: Data) -> Data {
        var bytes = prefix
        bytes.append(Data("{\(script.count)+}\r\n".utf8))
        bytes.append(script)
        bytes.append(contentsOf: [0x0d, 0x0a])
        return bytes
    }

    nonisolated private func emptyResult(_ response: ManageSieveCommandResponse) throws -> ManageSieveCommandResult {
        guard response.dataLines.isEmpty else { throw ManageSieveClientError.parse }
        return ManageSieveCommandResult(responseCode: response.status.responseCode, message: response.status.message)
    }

    private func scriptOperation<T: Sendable>(
        timeout: Duration?, command: Data,
        interpret: @escaping @Sendable (ManageSieveCommandResponse) throws -> T
    ) async throws -> T {
        try checkAdmission()
        guard state == .authenticated else { throw ManageSieveClientError.invalidState }
        admittedOperation = ManageSieveOperationAdmission()
        do {
            let value = try await withTimeout(timeout ?? timeoutPolicy.command) {
                try await self.sendBytes(command)
                let response = try await self.readResponse()
                guard response.dataLines.isEmpty || response.status.status == .ok else {
                    throw ManageSieveClientError.parse
                }
                try self.requireOK(response)
                return try interpret(response)
            }
            try ensureOpen()
            admittedOperation = nil
            return value
        } catch let error as ManageSieveClientError where error == .serverNo && state == .authenticated {
            admittedOperation = nil
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
        guard response.status.status == .ok || response.dataLines.isEmpty else {
            throw ManageSieveClientError.parse
        }
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
        admittedOperation = nil
    }

    private func closeForTermination() {
        guard state != .closed else { return }
        state = .closed
        capabilities = nil
        let transport = self.transport
        let logger = self.logger
        // Start closure before reporting termination; never wait for a stalled transport operation.
        Task {
            await transport.close()
            logger.record(.closed)
        }
    }

    private func sanitized(_ error: Error) -> ManageSieveClientError {
        if let clientError = error as? ManageSieveClientError { return clientError }
        if error is CancellationError { return .cancelled }
        return .transport
    }

    private func checkAdmission() throws {
        guard !Task.isCancelled else { throw ManageSieveClientError.cancelled }
        guard admittedOperation == nil else { throw ManageSieveClientError.operationInProgress }
    }

    // The client actor arbitrates every terminal path using the admitted operation's identity.
    private func claimOperation(_ token: UUID) -> Bool {
        guard admittedOperation?.id == token, admittedOperation?.settled == false else { return false }
        admittedOperation?.settled = true
        return true
    }

    private func terminateOperation(_ token: UUID, error: ManageSieveClientError) {
        guard claimOperation(token) else { return }
        logger.record(error == .timeout ? .timedOut : .cancelled)
        closeForTermination()
        admittedOperation?.terminate?(error)
        admittedOperation?.terminate = nil
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let token = admittedOperation?.id else { throw ManageSieveClientError.invalidState }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operationTask = Task { try await operation() }
                let timeoutTask = Task { [clock] in
                    do { try await clock.sleep(for: duration) } catch { return }
                    guard !Task.isCancelled else { return }
                    terminateOperation(token, error: .timeout)
                }
                admittedOperation?.terminate = { error in
                    operationTask.cancel()
                    timeoutTask.cancel()
                    continuation.resume(throwing: error)
                }
                Task {
                    let result = await operationTask.result
                    guard claimOperation(token) else { return }
                    admittedOperation?.terminate = nil
                    timeoutTask.cancel()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            Task { await self.terminateOperation(token, error: .cancelled) }
        }
    }
}
