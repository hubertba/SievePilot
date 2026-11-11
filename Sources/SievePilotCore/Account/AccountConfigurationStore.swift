import Darwin
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
        fileURL = directoryURL.appendingPathComponent("account.json", isDirectory: false)
        self.replace = replace
        self.setAttributes = setAttributes
    }

    internal static func atomicReplace(_ temporary: URL, _ destination: URL) throws {
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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
        try setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], directoryURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, account: validated))
        let temporary = directoryURL.appendingPathComponent(".account-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], temporary.path)
        // The atomic rename is the final fallible operation: a reported failure never follows a commit.
        try replace(temporary, fileURL)
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
