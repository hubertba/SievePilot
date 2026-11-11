import Foundation
import SwiftASN1
import X509
import XCTest
@testable import SievePilotCore

func tlsFixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
    return try Data(contentsOf: url)
}

// Deterministic test-only trust: never used by the production transport initializer.
struct FixtureTLSChainTrustEvaluator: TLSChainTrustEvaluating {
    var trusted = true
    var validationTime = Date(timeIntervalSince1970: 1_800_000_000)
    func evaluate(certificateChainDER: [Data]) async throws {
        let chain = try certificateChainDER.map { try Certificate(derEncoded: Array($0)) }
        guard let leaf = chain.first else { throw NIOTransportError.tlsTrustFailed }
        let root = try Certificate(derEncoded: Array(tlsFixture("ca.der")))
        var verifier = Verifier(rootCertificates: CertificateStore(trusted ? [root] : [])) {
            RFC5280Policy(validationTime: validationTime)
        }
        let result = await verifier.validate(leafCertificate: leaf, intermediates: CertificateStore(Array(chain.dropFirst())))
        guard case .validCertificate = result else { throw NIOTransportError.tlsTrustFailed }
    }
}

final class ManageSieveTLSIdentityValidatorTests: XCTestCase {
    private let validator = ManageSieveTLSIdentityValidator()

    private func certificate(_ names: [GeneralName]?) throws -> Certificate {
        let key = try Certificate.PrivateKey(pemEncoded: String(decoding: tlsFixture("server-key.pem"), as: UTF8.self))
        let name = try DistinguishedName { CommonName("cn-only.example.org") }
        return try Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: Date(timeIntervalSince1970: 1_600_000_000),
            notValidAfter: Date(timeIntervalSince1970: 2_200_000_000),
            issuer: name, subject: name, signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions {
                if let names { SubjectAlternativeNames(names) }
            }, issuerPrivateKey: key
        )
    }

    func testExactDNSCaseFoldingAndSourceDomainNotTarget() throws {
        let chain = [try Certificate(derEncoded: Array(tlsFixture("server.der")))]
        try validator.validate(certificateChain: chain, identifiers: [.dns("SOURCE.EXAMPLE.ORG")])
        XCTAssertThrowsError(try validator.validate(certificateChain: chain, identifiers: [.dns("target.example.net")])) {
            XCTAssertEqual($0 as? NIOTransportError, .tlsIdentityFailed)
        }
    }

    func testSRVIDIsTypedAndServiceSpecific() throws {
        let chain = [try Certificate(derEncoded: Array(tlsFixture("server.der")))]
        try validator.validate(certificateChain: chain, identifiers: [.srv(service: "sieve", domain: "SOURCE.EXAMPLE.ORG")])
        for id: ManageSieveReferenceIdentifier in [.srv(service: "imap", domain: "source.example.org"), .dns("_sieve.source.example.org")] {
            XCTAssertThrowsError(try validator.validate(certificateChain: chain, identifiers: [id]))
        }
        let srvOnly = try certificate([.otherName(.init(typeID: [1, 3, 6, 1, 5, 5, 7, 8, 7], value: try ASN1Any(erasing: ASN1IA5String("_sieve.source.example.org"))))])
        try validator.validate(certificateChain: [srvOnly], identifiers: [.srv(service: "sieve", domain: "source.example.org")])
        XCTAssertThrowsError(try validator.validate(certificateChain: [srvOnly], identifiers: [.dns("source.example.org")]))
    }

    func testOnlyWholeLeftmostSingleLabelWildcard() throws {
        let cert = try certificate([.dnsName("*.example.org")])
        try validator.validate(certificateChain: [cert], identifiers: [.dns("mail.example.org")])
        for name in ["example.org", "a.b.example.org"] {
            XCTAssertThrowsError(try validator.validate(certificateChain: [cert], identifiers: [.dns(name)]))
        }
        for pattern in ["ma*.example.org", "*.*.org", "mail.*.org"] {
            XCTAssertThrowsError(try validator.validate(certificateChain: [certificate([.dnsName(pattern)])], identifiers: [.dns("mail.example.org")]))
        }
    }

    func testSANOnlyNoCommonNameFallbackAndNoIssuerIdentity() throws {
        for cert in [try certificate(nil), try certificate([.dnsName("other.example.org")])] {
            XCTAssertThrowsError(try validator.validate(certificateChain: [cert], identifiers: [.dns("cn-only.example.org")]))
        }
        XCTAssertThrowsError(try validator.validate(certificateChain: [certificate(nil), certificate([.dnsName("source.example.org")])], identifiers: [.dns("source.example.org")]))
    }

    func testMalformedNamesAndEmptyIdentifiersFailClosed() throws {
        for name in ["", "a..org", "-a.org", "a-.org", "a.org\u{0}", "é.org", "a.org.", "127.0.0.1", "*.example.org", String(repeating: "a", count: 64) + ".org"] {
            XCTAssertThrowsError(try validator.validate(certificateChain: [certificate([.dnsName(name)])], identifiers: [.dns(name)]))
        }
        XCTAssertThrowsError(try validator.validate(certificateChain: [certificate([.dnsName("source.example.org")])], identifiers: []))
        XCTAssertThrowsError(try validator.validate(certificateChain: [], identifiers: [.dns("source.example.org")]))
    }

    func testFixtureChainRejectsExpiredAndUntrustedChains() async throws {
        let chain = [try tlsFixture("server.der"), try tlsFixture("ca.der")]
        try await FixtureTLSChainTrustEvaluator().evaluate(certificateChainDER: chain)
        for evaluator in [FixtureTLSChainTrustEvaluator(trusted: false), FixtureTLSChainTrustEvaluator(validationTime: Date(timeIntervalSince1970: 2_300_000_000))] {
            do { try await evaluator.evaluate(certificateChainDER: chain); XCTFail("Expected trust failure") }
            catch { XCTAssertEqual(error as? NIOTransportError, .tlsTrustFailed) }
        }
    }

    func testSystemTrustRejectsFixtureCAAndMalformedDER() async throws {
        for chain in [[try tlsFixture("server.der"), try tlsFixture("ca.der")], [Data([0])], []] {
            do { try await SecurityTLSChainTrustEvaluator().evaluate(certificateChainDER: chain); XCTFail("Fixture CA must not be system trusted") }
            catch { XCTAssertEqual(error as? NIOTransportError, .tlsTrustFailed) }
        }
    }
}
