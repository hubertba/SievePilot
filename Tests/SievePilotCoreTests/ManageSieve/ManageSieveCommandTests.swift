import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManageSieveCommandTests {
    private let identity = ManageSieveTLSIdentityRequest(referenceIdentifiers: ["mail.example.org"])
    private let secure = "\"IMPLEMENTATION\" \"test\"\r\n\"VERSION\" \"2\"\r\n\"SASL\" \"PLAIN\"\r\n\"SIEVE\" \"fileinto\"\r\nOK\r\n"

    private func client(_ suffix: [FakeManageSieveTransport.Step], authenticated: Bool = true, logger: any ManageSieveLogger = FakeManageSieveLogger()) async throws -> (FakeManageSieveTransport, ManageSieveClient) {
        let user = "test"
        let password = "secret"
        let payload = Data(([0] as [UInt8]) + Array(user.utf8) + [0] + Array(password.utf8)).base64EncodedString()
        let auth: [FakeManageSieveTransport.Step] = authenticated ? [
            .write(Data("AUTHENTICATE \"PLAIN\" \"\(payload)\"\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(secure.utf8)),
        ] : []
        let transport = FakeManageSieveTransport([
            .connect, .read(Data("\"STARTTLS\"\r\nOK\r\n".utf8)),
            .write(Data("STARTTLS\r\n".utf8)), .read(Data("OK\r\n".utf8)), .upgrade(identity),
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(secure.utf8)),
        ] + auth + suffix)
        let client = ManageSieveClient(transport: transport, clock: FakeManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: .production, logger: logger)
        _ = try await client.connectAndStartTLS(identity: identity)
        if authenticated { try await client.authenticatePlain(username: user, password: password) }
        return (transport, client)
    }

    private func expect(_ expected: ManageSieveClientError, _ action: () async throws -> Void) async {
        do { try await action(); Issue.record("Expected \(expected)") }
        catch { #expect(error as? ManageSieveClientError == expected) }
    }

    @Test func listScriptsAcceptsFragmentationAndRejectsBadShape() async throws {
        let (transport, client) = try await client([
            .write(Data("LISTSCRIPTS\r\n".utf8)), .read(Data("\"first\" ACTIVE\r".utf8)),
            .read(Data("\n\"second\"\r\nOK\r\n".utf8)),
        ])
        #expect(try await client.listScripts() == [ManageSieveScriptEntry(name: "first", isActive: true), ManageSieveScriptEntry(name: "second", isActive: false)])
        #expect(await transport.assertComplete())
        for wire in ["\"first\" ACTIVE\r\n\"second\" ACTIVE\r\nOK\r\n", "\"first\"\r\n\"first\"\r\nOK\r\n", "\"first\" bogus\r\nOK\r\n", "\"\"\r\nOK\r\n", "123\r\nOK\r\n", "NO\r\n"] {
            let (transport, client) = try await self.client([.write(Data("LISTSCRIPTS\r\n".utf8)), .read(Data(wire.utf8))])
            await expect(wire.hasSuffix("NO\r\n") ? .serverNo : .parse) { _ = try await client.listScripts() }
            #expect(await client.state == (wire.hasSuffix("NO\r\n") ? .authenticated : .closed))
            #expect(await transport.assertComplete())
        }
    }

    @Test func simpleCommandsAndNameEncoding() async throws {
        let (transport, client) = try await client([
            .write(Data("GETSCRIPT \"a\\\"b\\\\c\"\r\n".utf8)), .read(Data("{6}\r\n".utf8)),
            .read(Data([0xff, 0, 0x0d, 0x0a, 0x41, 0x0a] + Array("\r\nOK\r\n".utf8))),
            .write(Data("SETACTIVE \"\"\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .write(Data("DELETESCRIPT {2+}\r\n".utf8) + Data("é\r\n".utf8)), .read(Data("OK\r\n".utf8)),
        ])
        #expect(try await client.getScript(name: "a\"b\\c") == Data([0xff, 0, 0x0d, 0x0a, 0x41, 0x0a]))
        try await client.setActive(name: "")
        try await client.deleteScript(name: "é")
        #expect(await transport.assertComplete())
    }

    @Test func simpleCommandStatusesAndShape() async throws {
        for (wire, expected) in [("NO \"denied\"\r\n", ManageSieveClientError.serverNo), ("BYE\r\n", .serverBye), ("\"unexpected\"\r\n\"second\"\r\nOK\r\n", .parse)] {
            let (transport, client) = try await client([.write(Data("GETSCRIPT \"a\"\r\n".utf8)), .read(Data(wire.utf8))])
            await expect(expected) { _ = try await client.getScript(name: "a") }
            #expect(await client.state == (expected == .serverNo ? .authenticated : .closed))
            #expect(await transport.assertComplete())
        }
        let (transport, client) = try await client([.write(Data("LOGOUT\r\n".utf8)), .read(Data("BYE\r\n".utf8))])
        try await client.logout()
        #expect(await client.state == .closed)
        #expect(await transport.assertComplete())
    }

    @Test func invalidInputAndIllegalStateNeverWrite() async throws {
        let (transport, client) = try await client([])
        for name in ["", "bad\0name", "bad\rname", "bad\nname"] {
            await expect(.invalidScriptName) { _ = try await client.getScript(name: name) }
            await expect(.invalidScriptName) { _ = try await client.putScript(name: name, script: Data([65])) }
            await expect(.invalidScriptName) { try await client.deleteScript(name: name) }
        }
        #expect(await transport.assertComplete())
        let (otherTransport, other) = try await self.client([], authenticated: false)
        await expect(.invalidState) { _ = try await other.listScripts() }
        await expect(.invalidState) { _ = try await other.getScript(name: "x") }
        await expect(.invalidState) { _ = try await other.checkScript(Data([65])) }
        await expect(.invalidState) { _ = try await other.putScript(name: "x", script: Data([65])) }
        await expect(.invalidState) { try await other.setActive(name: "") }
        await expect(.invalidState) { try await other.deleteScript(name: "x") }
        await expect(.invalidState) { try await other.logout() }
        #expect(await otherTransport.assertComplete())
        let disconnectedTransport = FakeManageSieveTransport([])
        let disconnected = ManageSieveClient(transport: disconnectedTransport, clock: FakeManageSieveClock(),
            timeoutPolicy: ManageSieveTimeoutPolicy(connect: .seconds(5), startTLS: .seconds(5), authentication: .seconds(5), command: .seconds(5)),
            limits: .production, logger: FakeManageSieveLogger())
        await expect(.invalidState) { _ = try await disconnected.listScripts() }
        await expect(.invalidState) { _ = try await disconnected.getScript(name: "x") }
        await expect(.invalidState) { _ = try await disconnected.checkScript(Data([65])) }
        await expect(.invalidState) { _ = try await disconnected.putScript(name: "x", script: Data([65])) }
        await expect(.invalidState) { try await disconnected.setActive(name: "") }
        await expect(.invalidState) { try await disconnected.deleteScript(name: "x") }
        await expect(.invalidState) { try await disconnected.logout() }
        #expect(await disconnectedTransport.assertComplete())
    }

    @Test func scriptsSendLiteralAtomicallyAndPreserveWarnings() async throws {
        let bytes = Data([0xff, 0, 0x0d, 0x0a, 0x41, 0x0a])
        let logger = RecordingManageSieveLogger()
        let (transport, client) = try await client([
            .write(Data("CHECKSCRIPT {6+}\r\n".utf8) + bytes + Data("\r\n".utf8)), .read(Data("OK (WARNINGS) \"body warning\"\r\n".utf8)),
            .write(Data("PUTSCRIPT \"name\" {6+}\r\n".utf8) + bytes + Data("\r\n".utf8)), .read(Data("NO \"rejected\"\r\n".utf8)),
        ], logger: logger)
        let result = try await client.checkScript(bytes)
        #expect(result.responseCode == .list([.atom("WARNINGS")]))
        #expect(result.message == Data("body warning".utf8))
        await expect(.serverNo) { _ = try await client.putScript(name: "name", script: bytes) }
        let reported = logger.events.map { String(describing: $0) }.joined()
        #expect(!reported.contains("body warning"))
        #expect(await transport.readCount == 7) // handshake (3), auth (2), then one read per script command
        #expect(await transport.assertComplete())
    }

    @Test func failedScriptDoesNotLeakBodyAndRemainsRecoverable() async throws {
        let body = Data("SENSITIVE_SCRIPT_BODY_42\r\n".utf8)
        let logger = RecordingManageSieveLogger()
        let (transport, client) = try await client([
            .write(Data("CHECKSCRIPT {26+}\r\n".utf8) + body + Data("\r\n".utf8)),
            .read(Data("NO \"SENSITIVE_SERVER_MESSAGE_42\"\r\n".utf8)),
            .write(Data("LISTSCRIPTS\r\n".utf8)), .read(Data("OK\r\n".utf8)),
        ], logger: logger)
        var description = ""
        do { _ = try await client.checkScript(body); Issue.record("Expected NO") }
        catch { description = String(describing: error); #expect(error as? ManageSieveClientError == .serverNo) }
        #expect(try await client.listScripts().isEmpty)
        let reported = logger.events.map { String(describing: $0) }.joined() + description
        #expect(!reported.contains("SENSITIVE_SCRIPT_BODY_42"))
        #expect(!reported.contains("SENSITIVE_SERVER_MESSAGE_42"))
        #expect(await transport.assertComplete())
    }

    @Test func quotedStringBoundaryAndLiteralNames() async throws {
        let quoted = String(repeating: "a", count: 1022)
        let literal = String(repeating: "b", count: 1023)
        let (transport, client) = try await client([
            .write(Data("DELETESCRIPT \"\(quoted)\"\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .write(Data("DELETESCRIPT {1023+}\r\n\(literal)\r\n".utf8)), .read(Data("OK\r\n".utf8)),
        ])
        try await client.deleteScript(name: quoted)
        try await client.deleteScript(name: literal)
        #expect(await transport.assertComplete())
    }

    @Test func authenticatedCapabilityRejectsDataBeforeNo() async throws {
        let (transport, client) = try await client([
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data("123\r\nNO\r\n".utf8)),
        ])
        await expect(.parse) { _ = try await client.capability() }
        #expect(await client.state == .closed)
        #expect(await client.capabilities == nil)
        #expect(await transport.assertComplete())
    }

    @Test func quotedTabAndUnicodeControlLiteralRoundTrip() async throws {
        let tabName = "a\tb"
        let controlName = "a\u{0085}b"
        let controlBytes = Data(controlName.utf8)
        let (transport, client) = try await client([
            .write(Data("PUTSCRIPT \"a\tb\" {1+}\r\nx\r\n".utf8)), .read(Data("OK\r\n".utf8)),
            .write(Data("GETSCRIPT {\(controlBytes.count)+}\r\n".utf8) + controlBytes + Data("\r\n".utf8)),
            .read(Data("{1}\r\nx\r\nOK\r\n".utf8)),
            .write(Data("LISTSCRIPTS\r\n".utf8)),
            .read(Data("\"a\tb\" aCtIvE\r\n{\(controlBytes.count)}\r\n".utf8) + controlBytes + Data("\r\nOK\r\n".utf8)),
        ])
        _ = try await client.putScript(name: tabName, script: Data("x".utf8))
        #expect(try await client.getScript(name: controlName) == Data("x".utf8))
        #expect(try await client.listScripts() == [
            ManageSieveScriptEntry(name: tabName, isActive: true),
            ManageSieveScriptEntry(name: controlName, isActive: false),
        ])
        #expect(await transport.assertComplete())
    }

    @Test func listScriptsAcceptsLowercaseActive() async throws {
        let (transport, client) = try await client([
            .write(Data("LISTSCRIPTS\r\n".utf8)), .read(Data("\"CaseName\" active\r\nOK\r\n".utf8)),
        ])
        #expect(try await client.listScripts() == [ManageSieveScriptEntry(name: "CaseName", isActive: true)])
        #expect(await transport.assertComplete())
    }

    @Test func capabilityAfterAuthenticationAndLogoutOK() async throws {
        let (transport, client) = try await client([
            .write(Data("CAPABILITY\r\n".utf8)), .read(Data(secure.utf8)),
            .write(Data("LOGOUT\r\n".utf8)), .read(Data("OK\r\n".utf8)),
        ])
        #expect(try await client.capability(timeout: .seconds(1)).isAuthoritative)
        try await client.logout()
        #expect(await client.state == .closed)
        #expect(await transport.assertComplete())
    }

    @Test func malformedResponsesToSimpleCommandsClose() async throws {
        for (command, operation) in [("SETACTIVE \"x\"\r\n", 0), ("DELETESCRIPT \"x\"\r\n", 1), ("LOGOUT\r\n", 2)] {
            let (transport, client) = try await client([.write(Data(command.utf8)), .read(Data("\"unexpected\"\r\nOK\r\n".utf8))])
            switch operation {
            case 0: await expect(.parse) { try await client.setActive(name: "x") }
            case 1: await expect(.parse) { try await client.deleteScript(name: "x") }
            default: await expect(.parse) { try await client.logout() }
            }
            #expect(await client.state == .closed)
            #expect(await transport.assertComplete())
        }
    }

    @Test func scriptSizeValidationAndOverlaps() async throws {
        let (transport, client) = try await client([])
        await expect(.invalidScript) { _ = try await client.checkScript(Data()) }
        await expect(.invalidScript) { _ = try await client.putScript(name: "x", script: Data()) }
        await expect(.invalidScript) { _ = try await client.checkScript(Data(repeating: 65, count: 10 * 1024 * 1024 + 1)) }
        #expect(await transport.assertComplete())
        let (slow, active) = try await self.client([.write(Data("LISTSCRIPTS\r\n".utf8)), .slowRead])
        let pending = Task { try await active.listScripts(timeout: .seconds(1)) }
        while !(await slow.slowReadStarted) { await Task.yield() }
        await expect(.invalidState) { _ = try await active.getScript(name: "x") }
        await expect(.invalidState) { _ = try await active.checkScript(Data([65])) }
        await expect(.invalidState) { _ = try await active.putScript(name: "x", script: Data([65])) }
        await expect(.invalidState) { try await active.setActive(name: "x") }
        await expect(.invalidState) { try await active.deleteScript(name: "x") }
        await expect(.invalidState) { try await active.logout() }
        await expect(.invalidState) { _ = try await active.capability() }
        pending.cancel()
        await expect(.transport) { _ = try await pending.value }
        #expect(await slow.assertComplete())
    }
}
