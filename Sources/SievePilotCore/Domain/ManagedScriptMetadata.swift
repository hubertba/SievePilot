import Foundation

public enum ManagedScriptMetadataError: Error, Equatable, Sendable {
    case invalidPredecessorSHA256
}

public struct ManagedScriptMetadata: Codable, Equatable, Sendable {
    public let accountID: AccountID
    public let versionID: UUID
    public let predecessorSHA256: String?

    public init(
        accountID: AccountID,
        versionID: UUID,
        predecessorSHA256: String?
    ) throws {
        if let predecessorSHA256 {
            guard Self.isValidSHA256(predecessorSHA256) else {
                throw ManagedScriptMetadataError.invalidPredecessorSHA256
            }
            self.predecessorSHA256 = predecessorSHA256.lowercased()
        } else {
            self.predecessorSHA256 = nil
        }
        self.accountID = accountID
        self.versionID = versionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(AccountID.self, forKey: .accountID),
            versionID: container.decode(UUID.self, forKey: .versionID),
            predecessorSHA256: container.decodeIfPresent(String.self, forKey: .predecessorSHA256)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(versionID, forKey: .versionID)
        try container.encodeIfPresent(predecessorSHA256, forKey: .predecessorSHA256)
    }

    static func isValidSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x46).contains($0)
                || (0x61...0x66).contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case versionID
        case predecessorSHA256
    }
}
