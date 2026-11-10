import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ManageSieveCapabilityTests {
    @Test(arguments: [
        ("OK", ManageSieveStatus.ok),
        ("no", .no),
        ("ByE", .bye),
    ])
    func terminalStatusesAreCaseInsensitive(keyword: String, expected: ManageSieveStatus) throws {
        let response = try ManageSieveStatusResponse(
            line: ManageSieveWireLine(tokens: [.atom(keyword)])
        )

        #expect(response.status == expected)
        #expect(response.responseCode == nil)
        #expect(response.message == nil)
    }

    @Test func statusPreservesResponseCodeStructureAndRawMessageBytes() throws {
        let responseCode = ManageSieveToken.list([
            .atom("WARNINGS"),
            .number(3),
            .list([.atom("FUTURE"), .string(Data([0xff]))]),
        ])
        let message = Data([0x66, 0x61, 0x69, 0x6c, 0xff])

        let response = try ManageSieveStatusResponse(
            line: ManageSieveWireLine(tokens: [
                .atom("NO"),
                responseCode,
                .string(message),
            ])
        )

        #expect(response.responseCode == responseCode)
        #expect(response.message == message)
    }

    @Test func statusAcceptsMessageWithoutResponseCode() throws {
        let message = Data("ready".utf8)
        let response = try ManageSieveStatusResponse(
            line: ManageSieveWireLine(tokens: [.atom("OK"), .string(message)])
        )

        #expect(response.responseCode == nil)
        #expect(response.message == message)
    }

    @Test(arguments: [
        ManageSieveWireLine(tokens: []),
        ManageSieveWireLine(tokens: [.atom("MAYBE")]),
        ManageSieveWireLine(tokens: [.atom("OK"), .number(1)]),
        ManageSieveWireLine(tokens: [.atom("OK"), .string(Data()), .list([])]),
    ])
    func malformedStatusesAreRejected(line: ManageSieveWireLine) {
        #expect(throws: ManageSieveInterpretationError.malformedStatus) {
            try ManageSieveStatusResponse(line: line)
        }
    }

    @Test func commandResponseGroupsZeroOrMoreDataLinesWithOneTerminalStatus() throws {
        let emptyResponse = try ManageSieveCommandResponse(
            lines: [ManageSieveWireLine(tokens: [.atom("OK")])]
        )
        #expect(emptyResponse.dataLines.isEmpty)

        let dataLines = [
            ManageSieveWireLine(tokens: [.string(Data("one".utf8))]),
            ManageSieveWireLine(tokens: [.string(Data("two".utf8))]),
        ]
        let response = try ManageSieveCommandResponse(
            lines: dataLines + [ManageSieveWireLine(tokens: [.atom("ok")])]
        )

        #expect(response.dataLines == dataLines)
        #expect(response.status.status == .ok)
    }

    @Test func commandResponseRequiresExactlyOneFinalTerminalStatus() {
        #expect(throws: ManageSieveInterpretationError.missingTerminalStatus) {
            try ManageSieveCommandResponse(lines: [])
        }
        #expect(throws: ManageSieveInterpretationError.missingTerminalStatus) {
            try ManageSieveCommandResponse(lines: [
                ManageSieveWireLine(tokens: [.string(Data("data".utf8))]),
            ])
        }
        #expect(throws: ManageSieveInterpretationError.multipleTerminalStatuses) {
            try ManageSieveCommandResponse(lines: [
                ManageSieveWireLine(tokens: [.atom("NO")]),
                ManageSieveWireLine(tokens: [.atom("OK")]),
            ])
        }
    }

    @Test func capabilitiesAndListMembershipAreCaseInsensitive() throws {
        let capabilities = try parseCapabilities([
            strings("implementation", "Dovecot Pigeonhole"),
            strings("Version", "1.0"),
            strings("sAsL", "Plain LOGIN"),
            strings("SiEvE", "fileinto VACATION"),
            strings("starttls"),
        ])

        #expect(capabilities.containsCapability("IMPLEMENTATION"))
        #expect(capabilities.containsCapability("StartTLS"))
        #expect(capabilities.supportsSASLMechanism("PLAIN"))
        #expect(capabilities.supportsSASLMechanism("login"))
        #expect(capabilities.supportsSieveExtension("FILEINTO"))
        #expect(capabilities.supportsSieveExtension("vacation"))
        #expect(capabilities.implementation == Data("Dovecot Pigeonhole".utf8))
        #expect(capabilities.version == Data("1.0".utf8))
    }

    @Test func unknownCapabilitiesArePreserved() throws {
        let unknown = strings("X-FUTURE", "opaque Value")
        let capabilities = try parseCapabilities([
            strings("IMPLEMENTATION", "server"),
            strings("VERSION", "1"),
            strings("SASL", "PLAIN"),
            strings("SIEVE", "fileinto"),
            unknown,
        ])

        #expect(capabilities.containsCapability("x-future"))
        #expect(capabilities.unknownCapabilities == [
            ManageSieveCapability(
                name: Data("X-FUTURE".utf8),
                value: Data("opaque Value".utf8)
            ),
        ])
    }

    @Test(arguments: ["IMPLEMENTATION", "VERSION", "LANGUAGE"])
    func duplicateSingletonCapabilitiesAreRejected(name: String) {
        #expect(throws: ManageSieveInterpretationError.duplicateSingletonCapability(name)) {
            try parseCapabilities([
                strings(name, "first"),
                strings(name.lowercased(), "second"),
            ], origin: .preTLSGreeting)
        }
    }

    @Test(arguments: [
        ManageSieveWireLine(tokens: []),
        ManageSieveWireLine(tokens: [.string(Data("SASL".utf8)), .string(Data("PLAIN".utf8)), .string(Data("LOGIN".utf8))]),
        ManageSieveWireLine(tokens: [.atom("SASL"), .string(Data("PLAIN".utf8))]),
        ManageSieveWireLine(tokens: [.string(Data("SASL".utf8)), .number(1)]),
    ])
    func malformedCapabilityArityOrTokenTypesAreRejected(line: ManageSieveWireLine) {
        #expect(throws: ManageSieveInterpretationError.malformedCapability) {
            try parseCapabilities([line], origin: .preTLSGreeting)
        }
    }

    @Test(arguments: ["IMPLEMENTATION", "VERSION", "SASL", "SIEVE"])
    func postTLSCapabilitiesRequireAuthoritativeFields(missingName: String) {
        let lines = [
            strings("IMPLEMENTATION", "server"),
            strings("VERSION", "1"),
            strings("SASL", "PLAIN"),
            strings("SIEVE", "fileinto"),
        ].filter { line in
            guard case let .string(name) = line.tokens[0] else { return true }
            return String(decoding: name, as: UTF8.self) != missingName
        }

        #expect(throws: ManageSieveInterpretationError.missingAuthoritativeCapability(missingName)) {
            try parseCapabilities(lines)
        }
    }

    @Test func completePostTLSCapabilitiesAreAuthoritative() throws {
        let capabilities = try parseCapabilities([
            strings("IMPLEMENTATION", "server"),
            strings("VERSION", "1"),
            strings("SASL", "PLAIN"),
            strings("SIEVE", "fileinto"),
        ])

        #expect(capabilities.origin == .postTLSCapability)
        #expect(capabilities.isAuthoritative)
    }

    private func parseCapabilities(
        _ dataLines: [ManageSieveWireLine],
        origin: ManageSieveCapabilityOrigin = .postTLSCapability
    ) throws -> ManageSieveCapabilities {
        let response = try ManageSieveCommandResponse(
            lines: dataLines + [ManageSieveWireLine(tokens: [.atom("OK")])]
        )
        return try ManageSieveCapabilities(response: response, origin: origin)
    }

    private func strings(_ values: String...) -> ManageSieveWireLine {
        ManageSieveWireLine(tokens: values.map { .string(Data($0.utf8)) })
    }
}
