import Foundation

public enum OwnedScriptManifestPhase: String, Codable, Equatable, Sendable {
    case prepared
    case uploaded
    case verifiedActive
}

public struct OwnedScriptManifestRecord: Codable, Equatable, Sendable {
    public let accountID: AccountID
    public let name: String
    public let sha256: String
    public let predecessorName: String?
    public let predecessorSHA256: String?
    public let phase: OwnedScriptManifestPhase
    public let createdAt: Date

    public init(accountID: AccountID, name: String, sha256: String, predecessorName: String?,
                predecessorSHA256: String?, phase: OwnedScriptManifestPhase, createdAt: Date) {
        self.accountID = accountID
        self.name = name
        self.sha256 = sha256
        self.predecessorName = predecessorName
        self.predecessorSHA256 = predecessorSHA256
        self.phase = phase
        self.createdAt = createdAt
    }

    public func withPhase(_ phase: OwnedScriptManifestPhase) -> OwnedScriptManifestRecord {
        .init(accountID: accountID, name: name, sha256: sha256, predecessorName: predecessorName,
              predecessorSHA256: predecessorSHA256, phase: phase, createdAt: createdAt)
    }
}

public protocol OwnedScriptManifestStoring: Sendable {
    func load(accountID: AccountID) async throws -> [OwnedScriptManifestRecord]
    func save(_ record: OwnedScriptManifestRecord) async throws
}
