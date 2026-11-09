import Foundation

public struct ManagedScriptMetadata: Codable, Equatable, Sendable {
    public let accountID: AccountID
    public let versionID: UUID
    public let predecessorSHA256: String?

    public init(accountID: AccountID, versionID: UUID, predecessorSHA256: String?) {
        self.accountID = accountID
        self.versionID = versionID
        self.predecessorSHA256 = predecessorSHA256
    }
}
