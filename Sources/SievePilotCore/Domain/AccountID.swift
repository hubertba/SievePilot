import Foundation

public struct AccountID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var sieveToken: String {
        rawValue.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid account identifier")
        }
        rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sieveToken)
    }
}
