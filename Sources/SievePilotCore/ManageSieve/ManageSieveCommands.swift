import Foundation

public struct ManageSieveScriptEntry: Equatable, Sendable {
    public let name: String
    public let isActive: Bool

    public init(name: String, isActive: Bool) {
        self.name = name
        self.isActive = isActive
    }
}

public struct ManageSieveCommandResult: Equatable, Sendable {
    public let responseCode: ManageSieveToken?
    public let message: Data?

    public init(responseCode: ManageSieveToken?, message: Data?) {
        self.responseCode = responseCode
        self.message = message
    }
}

// RFC 2244 quoted strings admit non-NUL ASCII other than CR/LF; UTF-8 outside ASCII uses a literal.
enum ManageSieveCommandEncoding {
    static func name(_ name: String, allowEmpty: Bool, maximumLiteralLength: Int) throws -> Data {
        let bytes = Data(name.utf8)
        guard (allowEmpty || !bytes.isEmpty),
              !bytes.contains(where: { $0 == 0 || $0 == 0x0d || $0 == 0x0a }) else {
            throw ManageSieveClientError.invalidScriptName
        }
        if bytes.allSatisfy({ $0 <= 0x7e }) {
            var quoted = Data([0x22])
            for byte in bytes {
                if byte == 0x22 || byte == 0x5c { quoted.append(0x5c) }
                quoted.append(byte)
            }
            quoted.append(0x22)
            if quoted.count <= 1024 { return quoted }
        }
        guard bytes.count <= maximumLiteralLength else { throw ManageSieveClientError.invalidScriptName }
        var literal = Data("{\(bytes.count)+}\r\n".utf8)
        literal.append(bytes)
        return literal
    }
}
