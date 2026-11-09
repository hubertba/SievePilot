import Foundation

public struct AccountID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var sieveToken: String {
        rawValue.uuidString.lowercased()
    }
}
