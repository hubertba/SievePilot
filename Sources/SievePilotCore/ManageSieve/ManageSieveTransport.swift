import Foundation

public protocol ManageSieveTransport: AnyObject, Sendable {
    func connect() async throws
    func read(maxBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func upgradeToTLS(identity: ManageSieveTLSIdentityRequest) async throws
    // Closing must release any pending transport operations, even if they ignore task cancellation.
    func close() async
}

public struct ManageSieveTLSIdentityRequest: Equatable, Sendable {
    public let referenceIdentifiers: [String]

    public init(referenceIdentifiers: [String]) {
        self.referenceIdentifiers = referenceIdentifiers
    }
}
