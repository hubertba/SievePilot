import Foundation

public enum AccountEndpointPolicy: Equatable, Codable, Sendable {
    case automatic(sourceDomain: String)
    case manual(host: String, port: Int)

    private enum CodingKeys: String, CodingKey { case type, sourceDomain, host, port }
    private enum Kind: String, Codable { case automatic, manual }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .automatic:
            self = .automatic(sourceDomain: try container.decode(String.self, forKey: .sourceDomain))
        case .manual:
            self = .manual(host: try container.decode(String.self, forKey: .host),
                           port: try container.decode(Int.self, forKey: .port))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic(let sourceDomain):
            try container.encode(Kind.automatic, forKey: .type)
            try container.encode(sourceDomain, forKey: .sourceDomain)
        case .manual(let host, let port):
            try container.encode(Kind.manual, forKey: .type)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        }
    }
}

public enum AccountTLSPolicy: String, Codable, Sendable { case startTLS }

public enum AccountConfigurationError: Error, Equatable, Sendable {
    case invalidEmailAddress
    case invalidUsername
    case invalidEndpoint
}

public struct AccountConfiguration: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public var emailAddress: String
    public var username: String
    public var endpointPolicy: AccountEndpointPolicy
    public var tlsPolicy: AccountTLSPolicy

    public init(accountID: AccountID, emailAddress: String, username: String,
                endpointPolicy: AccountEndpointPolicy, tlsPolicy: AccountTLSPolicy) throws {
        let canonicalEmail = try Self.canonicalEmail(emailAddress)
        let canonicalUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalUsername.isEmpty,
              canonicalUsername.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw AccountConfigurationError.invalidUsername
        }
        let sourceDomain = String(canonicalEmail[canonicalEmail.index(after: canonicalEmail.lastIndex(of: "@")!)...])
        let canonicalEndpoint: AccountEndpointPolicy
        switch endpointPolicy {
        case .automatic(let domain):
            guard let canonical = SieveDNSName.canonical(domain), canonical == sourceDomain else {
                throw AccountConfigurationError.invalidEndpoint
            }
            canonicalEndpoint = .automatic(sourceDomain: canonical)
        case .manual(let host, let port):
            let unrooted = host.hasSuffix(".") ? String(host.dropLast()) : host
            guard (1...65_535).contains(port), let canonical = SieveDNSName.canonical(unrooted) else {
                throw AccountConfigurationError.invalidEndpoint
            }
            canonicalEndpoint = .manual(host: canonical, port: port)
        }
        self.accountID = accountID
        self.emailAddress = canonicalEmail
        self.username = canonicalUsername
        self.endpointPolicy = canonicalEndpoint
        self.tlsPolicy = tlsPolicy
    }

    private enum CodingKeys: String, CodingKey { case accountID, emailAddress, username, endpointPolicy, tlsPolicy }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(accountID: container.decode(AccountID.self, forKey: .accountID),
                      emailAddress: container.decode(String.self, forKey: .emailAddress),
                      username: container.decode(String.self, forKey: .username),
                      endpointPolicy: container.decode(AccountEndpointPolicy.self, forKey: .endpointPolicy),
                      tlsPolicy: container.decode(AccountTLSPolicy.self, forKey: .tlsPolicy))
    }

    private static func canonicalEmail(_ email: String) throws -> String {
        guard let at = email.lastIndex(of: "@"), at != email.startIndex,
              let domain = SieveDNSName.canonical(String(email[email.index(after: at)...])) else {
            throw AccountConfigurationError.invalidEmailAddress
        }
        return String(email[...at]) + domain
    }
}
