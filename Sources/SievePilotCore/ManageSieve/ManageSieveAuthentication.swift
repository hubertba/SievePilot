import Foundation

// Credential bytes live only in scoped buffers. Foundation Data and transport implementations
// may copy them; wiping these buffers cannot erase copies outside this client.
enum ManageSieveAuthentication {
    static func plain(username: String, password: String) -> Data {
        var raw = Data([0])
        raw.append(contentsOf: username.utf8)
        raw.append(0)
        raw.append(contentsOf: password.utf8)
        defer { wipe(&raw) }
        return raw.base64EncodedData()
    }

    static func login(_ value: String) -> Data {
        var raw = Data(value.utf8)
        defer { wipe(&raw) }
        return raw.base64EncodedData()
    }

    static func quoted(_ value: Data) -> Data {
        var result = Data([0x22])
        for byte in value {
            if byte == 0x22 || byte == 0x5c { result.append(0x5c) }
            result.append(byte)
        }
        result.append(0x22)
        return result
    }

    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { memset(base, 0, buffer.count) }
        }
        data.removeAll(keepingCapacity: false)
    }

    static func isBase64Challenge(_ value: Data) -> Bool {
        guard let decoded = Data(base64Encoded: value) else { return false }
        return decoded.base64EncodedData() == value
    }
}
