import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManageSieveBoundsAndCancellationTests {
    private let identity = ManageSieveTLSIdentityRequest(referenceIdentifiers: [.dns("mail.example.org")])
    private let secure = Data("\"IMPLEMENTATION\" \"fake\"\r\n\"VERSION\" \"2\"\r\n\"SIEVE\" \"fileinto\"\r\n\"SASL\" \"PLAIN LOGIN\"\r\nOK\r\n".utf8)
    private let user = "credential-user-sentinel-491"
    private let password = "credential-password-sentinel-682"

    private var handshake: [FakeManageSieveTransport.Step] {
        [.connect, .read(Data("\"STARTTLS\"\r\nOK\r\n".utf8)), .write(Data("STARTTLS\r\n".utf8)),
         .read(Data("OK\r\n".utf8)), .upgrade(identity), .write(Data("CAPABILITY\r\n".utf8)), .read(secure)]
    }

    private var plain: Data {
        let payload = Data(([0] as [UInt8]) + Array(user.utf8) + [0] + Array(password.utf8)).base64EncodedString()
        return Data("AUTHENTICATE \"PLAIN\" \"\(payload)\"\r\n".utf8)
    }

    private var authentication: [FakeManageSieveTransport.Step] {
        [.write(plain), .read(Data("OK\r\n".utf8)), .write(Data("CAPABILITY\r\n".utf8)), .read(secure)]
    }

    private func client(_ transport: FakeManageSieveTransport, _ clock: ManualManageSieveClock,
                        logger: any ManageSieveLogger = FakeManageSieveLogger()) -> ManageSieveClient {
        ManageSieveClient(transport: transport, clock: clock,
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(2), startTLS: .seconds(3),
                                                    authentication: .seconds(7), command: .seconds(11)),
            limits: .production, logger: logger)
    }

    @discardableResult private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<20_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        Issue.record("Deterministic control point was not reached")
        return false
    }

    private func expect(_ error: ManageSieveClientError, _ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected \(error)") }
        catch let actual { #expect(actual as? ManageSieveClientError == error) }
    }

    enum Stage: CaseIterable { case connect, greeting, startTLS, upgrade, capabilities, challenge, authRefresh, command, write }

    @Test(arguments: Stage.allCases, [false, true]) func absoluteDeadlineAtEverySuspension(stage: Stage, cancel: Bool) async throws {
        let steps: [FakeManageSieveTransport.Step]
        switch stage {
        case .connect: steps = [.suspendConnect]
        case .greeting: steps = [.connect, .suspendRead]
        case .startTLS: steps = Array(handshake.prefix(3)) + [.suspendRead]
        case .upgrade: steps = Array(handshake.prefix(4)) + [.suspendUpgrade(identity)]
        case .capabilities: steps = Array(handshake.prefix(6)) + [.suspendRead]
        case .challenge: steps = handshake + [.write(Data("AUTHENTICATE \"LOGIN\"\r\n".utf8)), .suspendRead]
        case .authRefresh: steps = handshake + Array(authentication.prefix(3)) + [.suspendRead]
        case .command: steps = handshake + authentication + [.write(Data("LISTSCRIPTS\r\n".utf8)), .suspendRead]
        case .write: steps = handshake + authentication + [.suspendWrite(Data("LISTSCRIPTS\r\n".utf8))]
        }
        let transport = FakeManageSieveTransport(steps)
        let clock = ManualManageSieveClock()
        let logger = RecordingManageSieveLogger()
        let client = client(transport, clock, logger: logger)
        if [.challenge, .authRefresh, .command, .write].contains(stage) {
            _ = try await client.connectAndStartTLS(identity: identity)
            await clock.fire()
        }
        if [.command, .write].contains(stage) {
            try await client.authenticatePlain(username: user, password: password)
            await clock.fire()
        }
        let previousTimers = await clock.durations.count
        let operation = Task {
            switch stage {
            case .challenge: try await client.authenticateLogin(username: user, password: password)
            case .authRefresh: try await client.authenticatePlain(username: user, password: password)
            case .command, .write: _ = try await client.listScripts()
            default: _ = try await client.connectAndStartTLS(identity: identity)
            }
        }
        await eventually { let connect = await transport.isConnectSuspended; let suspension = await transport.suspension; return connect || suspension != nil }
        await eventually { await clock.durations.count > previousTimers }
        let expected: Duration = [.challenge, .authRefresh].contains(stage) ? .seconds(7) :
            ([.command, .write].contains(stage) ? .seconds(11) : .seconds(5))
        #expect(await clock.durations.dropFirst(previousTimers) == [expected])
        let writes = await transport.writes
        if cancel {
            let completion = LifecycleCompletion()
            let observer = Task { _ = await operation.result; await completion.finish() }
            operation.cancel()
            if !(await eventually { await completion.finished }) { await clock.fire() }
            await expect(.cancelled) { try await operation.value }
            await observer.value
        } else {
            await clock.fire()
            await expect(.timeout) { try await operation.value }
        }
        await eventually { await transport.closeCount == 1 }
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        await expect(.invalidState) { _ = try await client.capability() }
        #expect(await transport.writes == writes)
        #expect(await transport.closeCount == 1)
        await eventually { logger.events.filter { $0 == .closed }.count == 1 }
        #expect(logger.events.filter { $0 == .timedOut || $0 == .cancelled } == [cancel ? .cancelled : .timedOut])
        #expect(await transport.assertComplete())
        await clock.fire()
    }

    @Test func slowFragmentsDoNotResetDeadline() async {
        let transport = FakeManageSieveTransport([.connect, .read(Data("\"START".utf8)),
                                                 .read(Data("TLS\"\r\n".utf8)), .suspendRead])
        let clock = ManualManageSieveClock()
        let client = client(transport, clock)
        let operation = Task { try await client.connectAndStartTLS(identity: identity, timeout: .seconds(13)) }
        await eventually { await transport.suspension == .read }
        await eventually { await clock.pendingCount == 1 }
        #expect(await transport.readCount == 3)
        #expect(await clock.durations == [.seconds(13)])
        await clock.fire()
        await expect(.timeout) { _ = try await operation.value }
        await eventually { await transport.closeCount == 1 }
        #expect(await transport.writes.isEmpty)
    }

    @Test func cancelledTimerCannotCloseCompletedOrSubsequentOperation() async throws {
        let transport = FakeManageSieveTransport(Array(handshake.dropLast()) + [.suspendRead,
            .write(Data("CAPABILITY\r\n".utf8)), .suspendRead])
        let clock = ManualManageSieveClock()
        let client = client(transport, clock)
        let first = Task { try await client.connectAndStartTLS(identity: identity) }
        await eventually { await transport.suspension == .read }
        await eventually { await clock.pendingCount == 1 }
        await transport.resumeSuspension(.success(secure))
        _ = try await first.value
        first.cancel() // Late caller cancellation must not own the next admission either.
        let second = Task { try await client.capability(timeout: .seconds(17)) }
        await eventually { await transport.suspension == .read }
        await eventually { await clock.pendingCount == 2 }
        await clock.fireNext() // The cancelled first timer deliberately ignores cancellation.
        await transport.resumeSuspension(.success(secure))
        _ = try await second.value
        await clock.fire()
        #expect(await client.state == .encryptedReady)
        #expect(await transport.closeCount == 0)
        #expect(await transport.assertComplete())
    }

    @Test func overlapAndCancellationBeforeAdmissionNeverTouchActiveOperation() async throws {
        let transport = FakeManageSieveTransport([.suspendConnect] + Array(handshake.dropFirst()))
        let clock = ManualManageSieveClock()
        let client = client(transport, clock)
        let active = Task { try await client.connectAndStartTLS(identity: identity) }
        await eventually { await transport.isConnectSuspended }
        await expect(.operationInProgress) { _ = try await client.connectAndStartTLS(identity: identity) }
        await expect(.operationInProgress) { _ = try await client.capability() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.connectAndStartTLS(identity: identity)
        }
        await expect(.cancelled) { _ = try await cancelled.value }
        #expect(await transport.closeCount == 0)
        #expect(await transport.writes.isEmpty)
        await transport.resumeConnect()
        _ = try await active.value
        await clock.fire()
        #expect(await client.state == .encryptedReady)
        #expect(await transport.closeCount == 0)
        #expect(await transport.assertComplete())
    }

    @Test(arguments: [false, true]) func completionRacingCancellationHasOneOutcome(fail: Bool) async throws {
        let transport = FakeManageSieveTransport(handshake + authentication +
            [.write(Data("LISTSCRIPTS\r\n".utf8)), .suspendRead])
        let clock = ManualManageSieveClock()
        let client = client(transport, clock)
        _ = try await client.connectAndStartTLS(identity: identity)
        await clock.fire()
        try await client.authenticatePlain(username: user, password: password)
        await clock.fire()
        let operation = Task { try await client.listScripts() }
        await eventually { await transport.suspension == .read }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { operation.cancel() }
            group.addTask {
                await transport.resumeSuspension(fail ? .failure(FakeError.injected) : .success(Data("OK\r\n".utf8)))
            }
        }
        do { #expect(try await operation.value.isEmpty) }
        catch { #expect([.cancelled, .transport].contains(error as? ManageSieveClientError)) }
        await clock.fire()
        #expect(await transport.closeCount <= 1)
        let writes = await transport.writes
        if await client.state == .closed {
            await eventually { await transport.closeCount == 1 }
            #expect(await transport.closeCount == 1)
            await expect(.invalidState) { _ = try await client.listScripts() }
        }
        #expect(await transport.writes == writes)
        #expect(await transport.assertComplete())
    }

    @Test func errorsAndEventsContainOnlyApprovedMetadata() async throws {
        let script = "script-body-sentinel-835"
        let challenge = "decoded-challenge-sentinel-726"
        let encodedChallenge = Data(challenge.utf8).base64EncodedString()
        let encodedPlain = Data(([0] as [UInt8]) + Array(user.utf8) + [0] + Array(password.utf8)).base64EncodedString()
        let sentinels = [user, password, script, challenge, encodedChallenge, encodedPlain,
                         Data(user.utf8).base64EncodedString(), Data(password.utf8).base64EncodedString()]
        let untrusted = sentinels.joined(separator: " ")
        let logger = RecordingManageSieveLogger()
        let transport = FakeManageSieveTransport(handshake + [
            .write(plain), .read(Data("NO \"\(untrusted)\"\r\n".utf8)),
            .write(Data("AUTHENTICATE \"LOGIN\"\r\n".utf8)),
            .read(Data("\"\(encodedChallenge)\"\r\n".utf8)),
            .write(Data("\"\(Data(user.utf8).base64EncodedString())\"\r\n".utf8)),
            .read(Data("NO \"\(untrusted)\"\r\n".utf8))
        ] + authentication + [
            .write(Data("CHECKSCRIPT {\(script.utf8.count)+}\r\n\(script)\r\n".utf8)),
            .read(Data("NO \"\(untrusted)\"\r\n".utf8))
        ])
        let clock = ManualManageSieveClock()
        let client = client(transport, clock, logger: logger)
        _ = try await client.connectAndStartTLS(identity: identity)
        await clock.fire()
        var errors: [String] = []
        for login in [false, true] {
            do {
                if login { try await client.authenticateLogin(username: user, password: password) }
                else { try await client.authenticatePlain(username: user, password: password) }
                Issue.record("Expected rejection")
            } catch { errors.append(String(reflecting: error)); #expect(error as? ManageSieveClientError == .serverNo) }
            await clock.fire()
        }
        try await client.authenticatePlain(username: user, password: password)
        await clock.fire()
        do { _ = try await client.checkScript(Data(script.utf8)); Issue.record("Expected rejection") }
        catch { errors.append(String(reflecting: error)); #expect(error as? ManageSieveClientError == .serverNo) }
        await clock.fire()
        let metadata = errors.joined() + String(reflecting: logger.events)
        for sentinel in sentinels { #expect(!metadata.contains(sentinel)) }
        #expect(logger.events == [.connected, .encrypted, .authenticationStarted(mechanism: "PLAIN"),
            .authenticationRejected, .authenticationStarted(mechanism: "LOGIN"), .authenticationRejected,
            .authenticationStarted(mechanism: "PLAIN"), .authenticated])
        #expect(await transport.closeCount == 0)
        #expect(await transport.assertComplete())
    }

}


private actor LifecycleCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}
