import Foundation

public actor OwnedScriptManifestStore: OwnedScriptManifestStoring {
    private let fileURL: URL

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("SievePilot/owned-scripts.json")
    }

    public func load(accountID: AccountID) async throws -> [OwnedScriptManifestRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.version == 1 else { throw ManifestStoreError.unsupportedVersion }
        return envelope.records.filter { $0.accountID == accountID }
    }

    public func save(_ record: OwnedScriptManifestRecord) async throws {
        var records: [OwnedScriptManifestRecord] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
            guard envelope.version == 1 else { throw ManifestStoreError.unsupportedVersion }
            records = envelope.records
        }
        records.removeAll { $0.accountID == record.accountID && $0.name == record.name }
        records.append(record)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, records: records))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                              ofItemAtPath: fileURL.path)
    }

    private struct Envelope: Codable { let version: Int; let records: [OwnedScriptManifestRecord] }
    public enum ManifestStoreError: Error { case unsupportedVersion }
}
