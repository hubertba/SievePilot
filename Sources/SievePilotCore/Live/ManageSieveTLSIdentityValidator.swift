import Foundation
import Security
import SwiftASN1
import X509

public protocol TLSChainTrustEvaluating: Sendable {
    func evaluate(certificateChainDER: [Data]) async throws
}

public struct SecurityTLSChainTrustEvaluator: TLSChainTrustEvaluating {
    private static let queue = DispatchQueue(label: "SievePilot.TLS.system-trust", qos: .userInitiated)

    public init() {}

    public func evaluate(certificateChainDER: [Data]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                let certificates = certificateChainDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                guard !certificates.isEmpty, certificates.count == certificateChainDER.count else {
                    continuation.resume(throwing: NIOTransportError.tlsTrustFailed)
                    return
                }
                // Trust the system's server-purpose chain decision, never the connection target's name.
                let policy = SecPolicyCreateSSL(true, nil)
                var trust: SecTrust?
                guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
                      let trust else {
                    continuation.resume(throwing: NIOTransportError.tlsTrustFailed)
                    return
                }
                let status = SecTrustEvaluateAsyncWithError(trust, Self.queue) { _, valid, _ in
                    if valid { continuation.resume() }
                    else { continuation.resume(throwing: NIOTransportError.tlsTrustFailed) }
                }
                if status != errSecSuccess { continuation.resume(throwing: NIOTransportError.tlsTrustFailed) }
            }
        }
    }
}

extension ManageSieveReferenceIdentifier {
    internal var isWellFormed: Bool {
        switch self {
        case .dns(let domain): return Self.domainLabels(domain) != nil
        case .srv(let service, let domain):
            return Self.validLabel(service) && Self.domainLabels(domain) != nil
        }
    }

    fileprivate static func validLabel(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        return !bytes.isEmpty && bytes.count <= 63 && alphanumeric(bytes[0]) && alphanumeric(bytes[bytes.count - 1]) && bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
    }

    fileprivate static func domainLabels(_ domain: String) -> [String]? {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard domain.utf8.count <= 253, labels.count >= 2, labels.allSatisfy(validLabel),
              !labels.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return labels.map { $0.lowercased() }
    }
}

public struct ManageSieveTLSIdentityValidator: Sendable {
    public init() {}

    public func validate(certificateChain: [Certificate], identifiers: [ManageSieveReferenceIdentifier]) throws {
        guard !identifiers.isEmpty, identifiers.allSatisfy(\.isWellFormed), let leaf = certificateChain.first else {
            throw NIOTransportError.tlsIdentityFailed
        }
        do {
            guard let names = try leaf.extensions.subjectAlternativeNames else { throw NIOTransportError.tlsIdentityFailed }
            for name in names {
                for identifier in identifiers {
                    switch (name, identifier) {
                    case (.dnsName(let presented), .dns(let reference)):
                        if Self.matchesDNS(presented, reference) { return }
                    case (.otherName(let other), .srv(let service, let domain)):
                        guard other.typeID == [1, 3, 6, 1, 5, 5, 7, 8, 7], let value = other.value,
                              let ia5 = try? ASN1IA5String(asn1Any: value) else { continue }
                        // SRV-ID is an IA5String: underscore + service label + exact domain (no wildcard).
                        if String(ia5).lowercased() == "_\(service.lowercased()).\(domain.lowercased())" { return }
                    default: continue
                    }
                }
            }
        } catch { throw NIOTransportError.tlsIdentityFailed }
        throw NIOTransportError.tlsIdentityFailed
    }

    private static func matchesDNS(_ presented: String, _ reference: String) -> Bool {
        guard let referenceLabels = ManageSieveReferenceIdentifier.domainLabels(reference) else { return false }
        if presented.hasPrefix("*.") {
            guard let suffix = ManageSieveReferenceIdentifier.domainLabels(String(presented.dropFirst(2))),
                  referenceLabels.count == suffix.count + 1 else { return false }
            return Array(referenceLabels.dropFirst()) == suffix
        }
        return ManageSieveReferenceIdentifier.domainLabels(presented) == referenceLabels
    }
}
