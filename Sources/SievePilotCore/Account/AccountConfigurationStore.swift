import Foundation

public protocol AccountConfigurationStoring: Sendable {
    func load() async throws -> AccountConfiguration?
    func save(_ configuration: AccountConfiguration) async throws
    func delete() async throws
}

public enum AccountConfigurationStoreError: Error, Equatable, Sendable {
    case corruptSettings
    case unsupportedVersion(Int)
}

public struct AccountConfigurationStore: AccountConfigurationStoring, @unchecked Sendable {
    internal let directoryURL: URL
    internal let fileURL: URL
    private let replace: @Sendable (URL, URL) throws -> Void

    public init(baseDirectory: URL) {
        self.init(baseDirectory: baseDirectory) { temporary, destination in
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        }
    }

    internal init(baseDirectory: URL, replace: @escaping @Sendable (URL, URL) throws -> Void) {
        directoryURL = baseDirectory.appendingPathComponent("SievePilot", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("account.json", isDirectory: false)
        self.replace = replace
    }

    public func load() async throws -> AccountConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw error }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else {
            throw AccountConfigurationStoreError.corruptSettings
        }
        guard version == 1 else { throw AccountConfigurationStoreError.unsupportedVersion(version) }
        do { return try JSONDecoder().decode(Envelope.self, from: data).account }
        catch { throw AccountConfigurationStoreError.corruptSettings }
    }

    public func save(_ configuration: AccountConfiguration) async throws {
        // Revalidate mutable public fields before persistence.
        let validated = try AccountConfiguration(accountID: configuration.accountID,
                                                 emailAddress: configuration.emailAddress,
                                                 username: configuration.username,
                                                 endpointPolicy: configuration.endpointPolicy,
                                                 tlsPolicy: configuration.tlsPolicy)
        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directoryURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, account: validated))
        let temporary = directoryURL.appendingPathComponent(".account-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: temporary.path)
        try replace(temporary, fileURL)
        try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }

    public func delete() async throws {
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    private struct Envelope: Codable {
        let version: Int
        let account: AccountConfiguration
    }
}
