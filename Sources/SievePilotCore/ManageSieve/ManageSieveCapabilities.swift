import Foundation

public enum ManageSieveCapabilityOrigin: Equatable, Sendable {
    case preTLSGreeting
    case postTLSCapability
}

public struct ManageSieveCapability: Equatable, Sendable {
    public let name: Data
    public let value: Data?

    public init(name: Data, value: Data? = nil) {
        self.name = name
        self.value = value
    }
}

public struct ManageSieveCapabilities: Equatable, Sendable {
    public let origin: ManageSieveCapabilityOrigin
    public let entries: [ManageSieveCapability]

    public var isAuthoritative: Bool {
        origin == .postTLSCapability
    }

    public var implementation: Data? {
        firstValue(for: "IMPLEMENTATION")
    }

    public var version: Data? {
        firstValue(for: "VERSION")
    }

    public var owner: Data? {
        firstValue(for: "OWNER")
    }

    public var language: Data? {
        firstValue(for: "LANGUAGE")
    }

    public var unknownCapabilities: [ManageSieveCapability] {
        entries.filter { !Self.knownCapabilityNames.contains(Self.foldedASCII($0.name)) }
    }

    public init(
        response: ManageSieveCommandResponse,
        origin: ManageSieveCapabilityOrigin
    ) throws {
        guard response.status.status == .ok else {
            throw ManageSieveInterpretationError.capabilityResponseRejected(response.status.status)
        }

        var entries: [ManageSieveCapability] = []
        var singletonNames: Set<Data> = []

        for line in response.dataLines {
            guard (1...2).contains(line.tokens.count),
                  case let .string(name) = line.tokens[0]
            else {
                throw ManageSieveInterpretationError.malformedCapability
            }

            let value: Data?
            if line.tokens.count == 2 {
                guard case let .string(parsedValue) = line.tokens[1] else {
                    throw ManageSieveInterpretationError.malformedCapability
                }
                value = parsedValue
            } else {
                value = nil
            }
            let capability = ManageSieveCapability(name: name, value: value)

            let foldedName = Self.foldedASCII(capability.name)
            if Self.singletonCapabilityNames.contains(foldedName),
               !singletonNames.insert(foldedName).inserted {
                throw ManageSieveInterpretationError.duplicateSingletonCapability(
                    String(decoding: foldedName, as: UTF8.self)
                )
            }
            entries.append(capability)
        }

        if origin == .postTLSCapability {
            for requiredName in Self.authoritativeCapabilityNames {
                guard entries.contains(where: {
                    Self.foldedASCII($0.name) == Data(requiredName.utf8)
                }) else {
                    throw ManageSieveInterpretationError.missingAuthoritativeCapability(requiredName)
                }
            }
        }

        self.origin = origin
        self.entries = entries
    }

    public func containsCapability(_ name: String) -> Bool {
        let foldedName = Self.foldedASCII(Data(name.utf8))
        return entries.contains { Self.foldedASCII($0.name) == foldedName }
    }

    public func supportsSASLMechanism(_ mechanism: String) -> Bool {
        containsListValue(mechanism, capabilityName: "SASL")
    }

    public func supportsSieveExtension(_ sieveExtension: String) -> Bool {
        containsListValue(sieveExtension, capabilityName: "SIEVE")
    }

    private func firstValue(for capabilityName: String) -> Data? {
        let foldedName = Data(capabilityName.utf8)
        return entries.first {
            Self.foldedASCII($0.name) == foldedName
        }?.value
    }

    private func containsListValue(_ value: String, capabilityName: String) -> Bool {
        let foldedCapabilityName = Data(capabilityName.utf8)
        let foldedValue = Self.foldedASCII(Data(value.utf8))

        return entries.lazy
            .filter { Self.foldedASCII($0.name) == foldedCapabilityName }
            .compactMap(\.value)
            .flatMap(Self.splitSpaceSeparatedList)
            .contains { Self.foldedASCII($0) == foldedValue }
    }

    private static func splitSpaceSeparatedList(_ data: Data) -> [Data] {
        var values: [Data] = []
        var valueStart: Data.Index?

        for index in data.indices {
            if data[index] == 0x20 {
                if let start = valueStart {
                    values.append(data[start..<index])
                    valueStart = nil
                }
            } else if valueStart == nil {
                valueStart = index
            }
        }
        if let start = valueStart {
            values.append(data[start..<data.endIndex])
        }
        return values
    }

    private static func foldedASCII(_ data: Data) -> Data {
        Data(data.map { byte in
            (0x61...0x7a).contains(byte) ? byte - 0x20 : byte
        })
    }

    private static let authoritativeCapabilityNames = [
        "IMPLEMENTATION",
        "VERSION",
        "SASL",
        "SIEVE",
    ]

    private static let singletonCapabilityNames: Set<Data> = [
        Data("IMPLEMENTATION".utf8),
        Data("VERSION".utf8),
        Data("LANGUAGE".utf8),
    ]

    private static let knownCapabilityNames: Set<Data> = [
        Data("STARTTLS".utf8),
        Data("SASL".utf8),
        Data("SIEVE".utf8),
        Data("IMPLEMENTATION".utf8),
        Data("VERSION".utf8),
        Data("OWNER".utf8),
        Data("LANGUAGE".utf8),
        Data("NOTIFY".utf8),
    ]
}
