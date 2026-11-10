import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManageSieveClientStateTests {
    private let identity = ManageSieveTLSIdentityRequest(referenceIdentifiers: ["mail.example.org"])
    private let postTLS = "\"IMPLEMENTATION\" \"secure\"\r\n\"VERSION\" \"2\"\r\n\"SASL\" \"PLAIN\"\r\n\"SIEVE\" \"fileinto\"\r\nOK\r\n"
    private let greeting = "\"STARTTLS\"\r\n\"SASL\" \"UNTRUSTED\"\r\n\"SIEVE\" \"unsafe\"\r\nOK\r\n"

    @Test func startTLSHandshakeDiscardsUntrustedGreetingAndUsesEncryptedCapabilities() async throws {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.prefix(18).utf8)),
            .read(Data(greeting.dropFirst(18).utf8)),
            .write(Data("STARTTLS\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .upgrade(identity), .write(Data("CAPABILITY\r\n".utf8)),
            .read(Data(postTLS.prefix(23).utf8)), .read(Data(postTLS.dropFirst(23).utf8)),
        ])
        let client = makeClient(transport)
        let capabilities = try await client.connectAndStartTLS(identity: identity)
        #expect(await client.state == .encryptedReady)
        #expect(capabilities.isAuthoritative)
        #expect(capabilities.implementation == Data("secure".utf8))
        #expect(capabilities.supportsSASLMechanism("PLAIN"))
        #expect(!capabilities.supportsSASLMechanism("UNTRUSTED"))
        #expect(!capabilities.supportsSieveExtension("unsafe"))
        #expect(await transport.assertComplete())
        #expect(await transport.closeCount == 0)
    }

    @Test(arguments: [
        ("NO\r\n", ManageSieveClientError.serverNo),
        ("BYE\r\n", .serverBye),
        ("OK 123\r\n", .parse),
        ("\"SASL\" \"PLAIN\"\r\nOK\r\n", .missingStartTLS),
        ("", .unexpectedEOF),
    ])
    func rejectedGreetingClosesExactlyOnce(wire: String, expected: ManageSieveClientError) async {
        let transport = FakeManageSieveTransport([.connect, .read(Data(wire.utf8))])
        let client = makeClient(transport)
        await expectError(expected) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
        #expect(await transport.writes.isEmpty)
        #expect(await transport.assertComplete())
    }

    @Test func oversizedGreetingClosesExactlyOnce() async {
        let transport = FakeManageSieveTransport([.connect, .read(Data("\"STARTTLS\"\r\nOK\r\n".utf8))])
        let client = makeClient(transport, limits: ManageSieveLimits(maximumLineLength: 3))
        await expectError(.parse) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await transport.closeCount == 1)
    }

    @Test(arguments: [
        ("NO\r\n", ManageSieveClientError.serverNo),
        ("BYE\r\n", .serverBye),
    ])
    func startTLSRejectionClosesExactlyOnce(wire: String, expected: ManageSieveClientError) async {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data(wire.utf8)),
        ])
        let client = makeClient(transport)
        await expectError(expected) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await transport.closeCount == 1)
        #expect(await transport.upgradeCount == 0)
        #expect(await transport.assertComplete())
    }

    @Test func startTLSRejectsUnexpectedDataBeforeTLSUpgrade() async {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("123\r\nOK\r\n".utf8)),
        ])
        let client = makeClient(transport)
        await expectError(.parse) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
        #expect(await transport.upgradeCount == 0)
        #expect(await transport.writes == [Data("STARTTLS\r\n".utf8)])
        #expect(await transport.assertComplete())
    }

    @Test func failedTLSUpgradeClosesExactlyOnce() async {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("OK\r\n".utf8)), .failure,
        ])
        let client = makeClient(transport)
        await expectError(.tls) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await transport.closeCount == 1)
        #expect(await transport.assertComplete())
    }

    @Test(arguments: [
        ("\"SASL\" \"PLAIN\"\r\nOK\r\n", ManageSieveClientError.parse),
        ("\"IMPLEMENTATION\" \"secure\"\r\nOK\r\n", .parse),
        ("BYE\r\n", .serverBye),
    ])
    func invalidEncryptedCapabilitiesNeverBecomeVisible(wire: String, expected: ManageSieveClientError) async {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("OK\r\n".utf8)), .upgrade(identity),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(wire.utf8)),
        ])
        let client = makeClient(transport)
        await expectError(expected) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
        #expect(await transport.assertComplete())
    }

    @Test(arguments: ["IMPLEMENTATION", "VERSION", "SASL", "SIEVE", "OWNER", "LANGUAGE", "NOTIFY", "STARTTLS"])
    func malformedRecognizedPostTLSCapabilityCloses(name: String) async {
        let wire: String
        if ["IMPLEMENTATION", "VERSION", "SASL", "SIEVE"].contains(name) {
            wire = postTLS.components(separatedBy: "\r\n").map { $0.hasPrefix("\"" + name + "\"") ? "\"" + name + "\"" : $0 }.joined(separator: "\r\n")
        } else {
            wire = "\"" + name + "\"" + (name == "STARTTLS" ? " \"\"" : "") + "\r\n" + postTLS
        }
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("OK\r\n".utf8)), .upgrade(identity),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(wire.utf8)),
        ])
        let client = makeClient(transport)
        await expectError(.parse) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        #expect(await transport.closeCount == 1)
        #expect(await transport.assertComplete())
    }


    @Test func capabilityRefreshReplacesOnlyOnOKRetainsOnNOAndClosesOnBYE() async throws {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("OK\r\n".utf8)), .upgrade(identity),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(postTLS.utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data("NO\r\n".utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(postTLS.replacingOccurrences(of: "secure", with: "new").utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data("BYE\r\n".utf8)),
        ])
        let client = makeClient(transport)
        let initial = try await client.connectAndStartTLS(identity: identity)
        await expectError(.serverNo) { try await client.capability() }
        #expect(await client.state == .encryptedReady)
        #expect(await client.capabilities == initial)
        let replacement = try await client.capability()
        #expect(replacement.implementation == Data("new".utf8))
        #expect(replacement != initial)
        #expect(await client.capabilities == replacement)
        await expectError(.serverBye) { try await client.capability() }
        await expectError(.invalidState) { try await client.capability() }
        #expect(await transport.closeCount == 1)
        #expect(await client.capabilities == nil)
        #expect(await transport.assertComplete())
    }

    @Test func malformedCapabilityRefreshClosesAndClearsSnapshot() async throws {
        let transport = FakeManageSieveTransport([
            .connect, .read(Data(greeting.utf8)), .write(Data("STARTTLS\r\n".utf8)),
            .read(Data("OK\r\n".utf8)), .upgrade(identity),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(postTLS.utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data("\"SASL\" \"PLAIN\"\r\nOK\r\n".utf8)),
        ])
        let client = makeClient(transport)
        _ = try await client.connectAndStartTLS(identity: identity)
        await expectError(.parse) { try await client.capability() }
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        #expect(await transport.closeCount == 1)
        #expect(await transport.assertComplete())
    }

    @Test func concurrentOperationIsRejectedBeforeTransportSuspension() async throws {
        let transport = FakeManageSieveTransport([
            .suspendConnect, .read(Data(greeting.utf8)),
            .write(Data("STARTTLS\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .upgrade(identity), .write(Data("CAPABILITY\r\n".utf8)), .read(Data(postTLS.utf8)),
        ])
        let client = makeClient(transport)
        let first = Task { try await client.connectAndStartTLS(identity: identity) }
        while !(await transport.isConnectSuspended) { await Task.yield() }
        await expectError(.operationInProgress) { try await client.connectAndStartTLS(identity: identity) }
        await expectError(.operationInProgress) { try await client.capability() }
        await transport.resumeConnect()
        _ = try await first.value
        #expect(await transport.assertComplete())
        #expect(await transport.closeCount == 0)
    }

    @Test func closingDuringSuspendedConnectCannotResurrectSession() async {
        let transport = FakeManageSieveTransport([.suspendConnect])
        let client = makeClient(transport)
        let pending = Task { try await client.connectAndStartTLS(identity: identity) }
        while !(await transport.isConnectSuspended) { await Task.yield() }
        await client.close()
        await transport.resumeConnect()
        await expectError(.invalidState) { try await pending.value }
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
        #expect(await transport.assertComplete())
    }

    @Test func connectFailureClosesExactlyOnce() async {
        let transport = FakeManageSieveTransport([.failure])
        let client = makeClient(transport)
        await expectError(.transport) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await transport.closeCount == 1)
        #expect(await transport.assertComplete())
    }

    @Test func absoluteHandshakeTimeoutClosesExactlyOnce() async {
        let transport = FakeManageSieveTransport([.connect, .slowRead])
        let client = ManageSieveClient(
            transport: transport, clock: ImmediateManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(1), startTLS: .seconds(1), authentication: .seconds(1), command: .seconds(1)),
            limits: .production, logger: FakeManageSieveLogger()
        )
        await expectError(.timeout) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
    }

    @Test func cancellingCallerCancelsReadAndClosesBeforeDeadline() async {
        let transport = FakeManageSieveTransport([.connect, .slowRead])
        let client = makeClient(transport)
        let completion = TimeoutCompletion()
        let pending = Task {
            do {
                _ = try await client.connectAndStartTLS(identity: identity, timeout: .seconds(1))
                await completion.complete(nil)
            } catch {
                await completion.complete(error as? ManageSieveClientError)
            }
        }
        while !(await transport.slowReadStarted) { await Task.yield() }
        pending.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await completion.didComplete, "Caller cancellation must not wait for the 1s deadline")
        await pending.value // The RED implementation finishes at its one-second deadline.
        #expect(await completion.error == .cancelled)
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        #expect(await transport.closeCount == 1)
        #expect(await transport.writes.isEmpty)
        #expect(await transport.assertComplete())
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
    }

    @Test func suspendedConnectTimesOutWithoutWaitingForOperationCancellation() async {
        let transport = FakeManageSieveTransport([.suspendConnect])
        let client = ManageSieveClient(
            transport: transport, clock: ImmediateManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(1), startTLS: .seconds(1), authentication: .seconds(1), command: .seconds(1)),
            limits: .production, logger: FakeManageSieveLogger()
        )
        let completion = TimeoutCompletion()
        let pending = Task {
            do { _ = try await client.connectAndStartTLS(identity: identity); await completion.complete(nil) }
            catch { await completion.complete(error as? ManageSieveClientError) }
        }
        while !(await transport.isConnectSuspended) { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(150))
        let delivered = await completion.didComplete
        #expect(delivered, "Timeout must return even when connect ignores cancellation")
        #expect(await client.state == .closed)
        #expect(await transport.closeCount == 1)
        #expect(await transport.writes.isEmpty)
        if !delivered { await transport.resumeConnect() } // Unblock the pre-fix implementation.
        await pending.value
        #expect(await completion.error == .timeout)
        #expect(await transport.assertComplete())
    }

    @Test func invalidIdentityAndIllegalOperationsSendNoBytes() async throws {
        let transport = FakeManageSieveTransport([])
        let client = makeClient(transport)
        await expectError(.invalidIdentity) {
            try await client.connectAndStartTLS(identity: ManageSieveTLSIdentityRequest(referenceIdentifiers: []))
        }
        await expectError(.invalidState) { try await client.capability() }
        #expect(await client.state == .disconnected)
        await client.close()
        await client.close()
        await expectError(.invalidState) { try await client.capability() }
        await expectError(.invalidState) { try await client.connectAndStartTLS(identity: identity) }
        #expect(await transport.writes.isEmpty)
        #expect(await transport.closeCount == 1)
    }

    private func expectError<T>(
        _ expected: ManageSieveClientError,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(expected)")
        } catch {
            #expect(error as? ManageSieveClientError == expected)
        }
    }

    private func makeClient(_ transport: FakeManageSieveTransport, limits: ManageSieveLimits = .production) -> ManageSieveClient {
        ManageSieveClient(
            transport: transport, clock: FakeManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: limits, logger: FakeManageSieveLogger()
        )
    }
}

private actor TimeoutCompletion {
    private(set) var didComplete = false
    private(set) var error: ManageSieveClientError?

    func complete(_ error: ManageSieveClientError?) {
        self.error = error
        didComplete = true
    }
}
