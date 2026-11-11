import Foundation

public struct SieveSRVRecord: Equatable, Sendable {
    public let priority: UInt16
    public let weight: UInt16
    public let port: UInt16
    public let target: String

    public init(priority: UInt16, weight: UInt16, port: UInt16, target: String) {
        self.priority = priority
        self.weight = weight
        self.port = port
        self.target = target
    }
}

public struct SieveServiceEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let referenceIdentifiers: [ManageSieveReferenceIdentifier]

    public init(host: String, port: Int, referenceIdentifiers: [ManageSieveReferenceIdentifier]) {
        self.host = host
        self.port = port
        self.referenceIdentifiers = referenceIdentifiers
    }
}

public protocol SieveSRVResolving: Sendable {
    func records(for name: String) async throws -> [SieveSRVRecord]
}

public protocol SieveRandomSource: Sendable {
    /// Returns a value in 0..<upperBound; upperBound is always positive.
    func next(upperBound: UInt64) -> UInt64
}

public struct SystemSieveRandomSource: SieveRandomSource {
    public init() {}
    public func next(upperBound: UInt64) -> UInt64 { UInt64.random(in: 0..<upperBound) }
}

public enum SieveServiceDiscoveryError: Error, Equatable, Sendable {
    case invalidEmailAddress
    case invalidRecord
    case noRecords
    case serviceUnavailable
    case weightOverflow
    case invalidRandomValue
    case invalidConfiguration
    case responseLimitExceeded
    case timedOut
    case dnsService(Int32)
}

public struct SieveServiceDiscovery: Sendable {
    private let resolver: any SieveSRVResolving
    private let random: any SieveRandomSource

    public init(resolver: any SieveSRVResolving, random: any SieveRandomSource) {
        self.resolver = resolver
        self.random = random
    }

    public func discover(emailAddress: String) async throws -> SieveServiceEndpoint {
        try Task.checkCancellation()
        guard let at = emailAddress.lastIndex(of: "@"), at != emailAddress.startIndex,
              let sourceDomain = SieveDNSName.canonical(String(emailAddress[emailAddress.index(after: at)...])) else {
            throw SieveServiceDiscoveryError.invalidEmailAddress
        }
        let answer = try await resolver.records(for: "_sieve._tcp.\(sourceDomain)")
        try Task.checkCancellation()
        let records = try answer.map { try $0.normalized() }
        guard let priority = records.map(\.priority).min() else { throw SieveServiceDiscoveryError.noRecords }
        let candidates = records.filter { $0.priority == priority }.sorted(by: SieveSRVRecord.canonicalOrder)
        let total = try Self.checkedWeightTotal(candidates.map { UInt64($0.weight) })
        let bound = total == 0 ? UInt64(candidates.count) : total
        let draw = random.next(upperBound: bound)
        guard draw < bound else { throw SieveServiceDiscoveryError.invalidRandomValue }
        let selected: SieveSRVRecord
        if total == 0 {
            selected = candidates[Int(draw)]
        } else {
            // The checked total also proves each partial sum fits UInt64.
            var cumulative: UInt64 = 0
            selected = candidates.first {
                cumulative += UInt64($0.weight)
                return draw < cumulative
            }!
        }
        return SieveServiceEndpoint(host: selected.target, port: Int(selected.port), referenceIdentifiers: [
            .srv(service: "sieve", domain: sourceDomain), .dns(sourceDomain)
        ])
    }

    internal static func checkedWeightTotal(_ weights: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 0
        for weight in weights {
            let (sum, overflow) = total.addingReportingOverflow(weight)
            guard !overflow else { throw SieveServiceDiscoveryError.weightOverflow }
            total = sum
        }
        return total
    }
}

internal enum SieveDNSName {
    static func canonical(_ name: String) -> String? {
        // Share the TLS reference-name policy: ASCII, >=2 DNS labels, no root dot or IP literal.
        guard ManageSieveReferenceIdentifier.dns(name).isWellFormed else { return nil }
        return name.lowercased()
    }
}

extension SieveSRVRecord {
    internal func normalized() throws -> SieveSRVRecord {
        guard target != "." else { throw SieveServiceDiscoveryError.serviceUnavailable }
        let name = target.hasSuffix(".") ? String(target.dropLast()) : target
        guard port != 0, let canonical = SieveDNSName.canonical(name) else { throw SieveServiceDiscoveryError.invalidRecord }
        return SieveSRVRecord(priority: priority, weight: weight, port: port, target: canonical)
    }

    internal static func canonicalOrder(_ lhs: SieveSRVRecord, _ rhs: SieveSRVRecord) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.target != rhs.target { return lhs.target < rhs.target }
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        return lhs.weight < rhs.weight
    }
}
