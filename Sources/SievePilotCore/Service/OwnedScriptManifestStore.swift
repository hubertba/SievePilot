import Darwin
import Foundation

public actor OwnedScriptManifestStore: OwnedScriptManifestStoring {
    internal nonisolated let directoryURL: URL
    internal nonisolated let fileURL: URL
    private let replace: (URL, URL) throws -> Void
    private let setAttributes: ([FileAttributeKey: Any], String) throws -> Void

    public init(baseDirectory: URL) {
        self.init(baseDirectory: baseDirectory, replace: Self.atomicReplace)
    }

    internal init(baseDirectory: URL, replace: @escaping (URL, URL) throws -> Void) {
        self.init(baseDirectory: baseDirectory, replace: replace) { attributes, path in
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        }
    }

    internal init(baseDirectory: URL, replace: @escaping (URL, URL) throws -> Void,
                  setAttributes: @escaping ([FileAttributeKey: Any], String) throws -> Void) {
        directoryURL = baseDirectory.appendingPathComponent("SievePilot", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("owned-scripts.json")
        self.replace = replace
        self.setAttributes = setAttributes
    }

    internal static func atomicReplace(_ temporary: URL, _ destination: URL) throws {
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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

        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], directoryURL.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, records: records))
        let temporary = directoryURL.appendingPathComponent(".owned-scripts-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], temporary.path)
        // Atomic rename is the final fallible operation, so a thrown save never follows a commit.
        try replace(temporary, fileURL)
    }

    private struct Envelope: Codable { let version: Int; let records: [OwnedScriptManifestRecord] }
    public enum ManifestStoreError: Error { case unsupportedVersion }
}
