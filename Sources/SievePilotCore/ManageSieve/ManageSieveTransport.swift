import Foundation

public protocol ManageSieveTransport: AnyObject, Sendable {
    func connect() async throws
    func read(maxBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func upgradeToTLS(identity: ManageSieveTLSIdentityRequest) async throws
    // Closing must release any pending transport operations, even if they ignore task cancellation.
    func close() async
}

public enum ManageSieveReferenceIdentifier: Equatable, Sendable {
    case dns(String)
    // Service label without the leading underscore, e.g. "sieve".
    case srv(service: String, domain: String)
}

public struct ManageSieveTLSIdentityRequest: Equatable, Sendable {
    public let referenceIdentifiers: [ManageSieveReferenceIdentifier]

    public init(referenceIdentifiers: [ManageSieveReferenceIdentifier]) {
        self.referenceIdentifiers = referenceIdentifiers
    }
}
