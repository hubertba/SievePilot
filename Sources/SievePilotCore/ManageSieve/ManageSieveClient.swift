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
    case tlsTrustFailed
    case tlsIdentityFailed
    case timeout
    case serverNo
    /// A script command answered `NO` with a `QUOTA` response code (RFC 5804 §1.3). Like `serverNo`, the
    /// session stays usable. Only the code's category is kept; the server's text is discarded.
    case quotaExceeded
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
    private var leftoverParser: ManageSieveResponseParser
    private var leftoverLines: [ManageSieveWireLine] = []
    private var inboundTrace = Data()

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
        leftoverParser = ManageSieveResponseParser(limits: limits)
    }

    public func connectAndStartTLS(
        identity: ManageSieveTLSIdentityRequest,
        timeout: Duration? = nil
    ) async throws -> ManageSieveCapabilities {
        try checkAdmission()
        guard state == .disconnected else { throw ManageSieveClientError.invalidState }
        guard !identity.referenceIdentifiers.isEmpty,
              identity.referenceIdentifiers.allSatisfy(\.isWellFormed) else {
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
                command.append(ManageSieveAuthentication.string(payload))
                command.append(contentsOf: [0x0d, 0x0a])
                defer { ManageSieveAuthentication.wipe(&command) }
                try await self.sendBytes(command)
                try await self.completePlainAuthentication(try await self.readResponse())
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
                for value in [username, password] {
                    let line = try await self.nextLine()
                    if line.startsWithTerminalStatus, await self.hasUnconsumedInbound {
                        throw ManageSieveClientError.parse
                    }
                    try self.requireChallenge(line)
                    if await self.leftoverLines.contains(where: \.startsWithTerminalStatus) {
                        throw ManageSieveClientError.parse
                    }
                    var encoded = ManageSieveAuthentication.login(value)
                    defer { ManageSieveAuthentication.wipe(&encoded) }
                    var command = ManageSieveAuthentication.string(encoded)
                    command.append(contentsOf: [0x0d, 0x0a])
                    defer { ManageSieveAuthentication.wipe(&command) }
                    try await self.sendBytes(command)
                }
                let terminal = try await self.nextLine()
                guard terminal.startsWithTerminalStatus else { throw ManageSieveClientError.parse }
                let response: ManageSieveCommandResponse
                do { response = try ManageSieveCommandResponse(lines: [terminal]) }
                catch { throw ManageSieveClientError.parse }
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

    private func admitAuthentication(_ mechanism: String) throws {
        try checkAdmission()
        guard state == .encryptedReady, let capabilities,
              capabilities.isAuthoritative else { throw ManageSieveClientError.invalidState }
        guard capabilities.supportsSASLMechanism(mechanism) else {
            throw ManageSieveClientError.unsupportedMechanism
        }
    }

    private func completePlainAuthentication(_ response: ManageSieveCommandResponse) async throws {
        if response.dataLines.isEmpty {
            try requireOK(response)
            try await finishAuthentication()
            return
        }
        // Dovecot may attach the post-auth capability listing to AUTHENTICATE's OK.
        let caps = try interpretCapabilities(response, origin: .postAuthentication)
        try ensureOpen()
        capabilities = caps
        state = .authenticated
        logger.record(.authenticated)
    }

    private func finishAuthentication() async throws {
        do {
            // Dovecot (and RFC 5804 when a SASL layer is negotiated) may already have
            // written the post-auth capability block after AUTHENTICATE's OK. Consume it
            // if it is already buffered; otherwise ask. Sending CAPABILITY while that
            // block is pending leaves the later reply for LISTSCRIPTS.
            let replacement = hasUnconsumedInbound
                ? try interpretCapabilities(try await readResponse(), origin: .postAuthentication)
                : try await refreshCapabilities()
            try ensureOpen()
            capabilities = replacement
            state = .authenticated
            logger.record(.authenticated)
        } catch {
            await close()
            throw sanitized(error)
        }
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
                if response.status.status == .no, Self.isQuotaResponseCode(response.status.responseCode) {
                    throw ManageSieveClientError.quotaExceeded
                }
                try self.requireOK(response)
                return try interpret(response)
            }
            try ensureOpen()
            admittedOperation = nil
            return value
        } catch let error as ManageSieveClientError
                    where (error == .serverNo || error == .quotaExceeded) && state == .authenticated {
            admittedOperation = nil
            throw error
        } catch {
            await closeAfterFailure()
            throw sanitized(error)
        }
    }

    /// `QUOTA`, `QUOTA/MAXSCRIPTS`, and `QUOTA/MAXSIZE` (RFC 5804 §1.3), matched case-insensitively.
    private static func isQuotaResponseCode(_ code: ManageSieveToken?) -> Bool {
        guard case let .list(tokens)? = code, case let .atom(name)? = tokens.first else { return false }
        let folded = name.uppercased()
        return folded == "QUOTA" || folded.hasPrefix("QUOTA/")
    }

    public func close() async {
        guard state != .closed else { return }
        state = .closed
        capabilities = nil
        resetInboundFraming()
        await transport.close()
        logger.record(.closed)
    }

    private func performHandshake(identity: ManageSieveTLSIdentityRequest) async throws -> ManageSieveCapabilities {
        inboundTrace = Data()
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
        // Preserve any coalesced TLS-record suffix in the transport, starting at a record boundary.
        let response = try await readResponse(maxBytes: 1)
        try requireOK(response)
        guard response.dataLines.isEmpty else { throw ManageSieveClientError.parse }
        resetInboundFraming()
        do { try await transport.upgradeToTLS(identity: identity) } catch {
            switch error as? NIOTransportError {
            case .tlsTrustFailed: throw ManageSieveClientError.tlsTrustFailed
            case .tlsIdentityFailed: throw ManageSieveClientError.tlsIdentityFailed
            default: throw ManageSieveClientError.tls
            }
        }
        // No greeting-derived fields survive the upgrade or become authoritative.
        capabilities = nil
        try ensureOpen()
        logger.record(.encrypted)
        // RFC 5804 §2.2: once TLS is established the server re-issues its capabilities, followed by OK,
        // without being asked. Consume that block here. Writing CAPABILITY first would queue a second
        // reply behind it and leave every later command reading the previous command's response. A
        // server that never re-issues is ended by the handshake deadline, never by a competing command.
        let secure = try interpretCapabilities(try await readResponse(), origin: .postTLSCapability)
        try ensureOpen()
        capabilities = secure
        state = .encryptedReady
        return secure
    }

    /// Explicit refresh. PLAIN and LOGIN negotiate no SASL security layer, so the server sends no
    /// capability block of its own after authentication and the client must ask.
    private func refreshCapabilities() async throws -> ManageSieveCapabilities {
        try await send("CAPABILITY\r\n")
        return try interpretCapabilities(try await readResponse(), origin: .postAuthentication)
    }

    private func interpretCapabilities(
        _ response: ManageSieveCommandResponse,
        origin: ManageSieveCapabilityOrigin
    ) throws -> ManageSieveCapabilities {
        guard response.status.status == .ok || response.dataLines.isEmpty else {
            throw ManageSieveClientError.parse
        }
        try requireOK(response)
        return try interpret(response, origin: origin)
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

    private var hasUnconsumedInbound: Bool {
        !leftoverLines.isEmpty || leftoverParser.bufferedByteCount > 0
    }

    private func resetInboundFraming() {
        leftoverParser = ManageSieveResponseParser(limits: limits)
        leftoverLines = []
    }

    private func recordInbound(_ data: Data) {
        inboundTrace.append(data)
        if inboundTrace.count > 32 * 1024 {
            inboundTrace.removeFirst(inboundTrace.count - 32 * 1024)
        }
    }

    private func nextLine(maxBytes: Int = 4096) async throws -> ManageSieveWireLine {
        if leftoverLines.isEmpty {
            while leftoverLines.isEmpty {
                try ensureOpen()
                let bytes: Data
                do { bytes = try await transport.read(maxBytes: maxBytes) } catch {
                    throw ManageSieveClientError.transport
                }
                try ensureOpen()
                guard !bytes.isEmpty else {
                    do { try leftoverParser.finish() } catch { throw ManageSieveClientError.parse }
                    throw ManageSieveClientError.unexpectedEOF
                }
                recordInbound(bytes)
                do { leftoverLines.append(contentsOf: try leftoverParser.feed(bytes)) } catch {
                    throw ManageSieveClientError.parse
                }
            }
        }
        return leftoverLines.removeFirst()
    }

    private func readResponse(maxBytes: Int = 4096) async throws -> ManageSieveCommandResponse {
        var lines: [ManageSieveWireLine] = []
        while true {
            let line = try await nextLine(maxBytes: maxBytes)
            lines.append(line)
            if line.startsWithTerminalStatus {
                do { return try ManageSieveCommandResponse(lines: lines) }
                catch { throw ManageSieveClientError.parse }
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
        let clientError: ManageSieveClientError
        if let error = error as? ManageSieveClientError { clientError = error }
        else if error is CancellationError { clientError = .cancelled }
        else { clientError = .transport }
        if clientError == .parse { Self.writeInboundDump(inboundTrace) }
        return clientError
    }

    /// Debug aid: last inbound bytes that failed to parse. Server-to-client only (no AUTHENTICATE payload).
    private static func writeInboundDump(_ data: Data) {
        var escaped = ""
        escaped.reserveCapacity(data.count * 2)
        for byte in data {
            switch byte {
            case 0x0d: escaped.append("\\r")
            case 0x0a: escaped.append("\\n\n")
            case 0x09: escaped.append("\\t")
            case 0x20...0x7e: escaped.append(Character(UnicodeScalar(byte)))
            default: escaped.append(contentsOf: String(format: "\\x%02x", byte))
            }
        }
        let body = "SievePilot last inbound from the server:\n\n\(escaped)\n"
        try? body.write(to: URL(fileURLWithPath: "/tmp/sievepilot-last-response.txt"), atomically: true, encoding: .utf8)
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
