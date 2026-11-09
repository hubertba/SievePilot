import Foundation

public enum SieveStringEncodingError: Error, Equatable, Sendable {
    case unsupportedControlCharacter
}

public enum SieveStringEncoder {
    public static func encodeQuoted(_ value: String) throws -> Data {
        try encodeQuoted(value, allowsLineBreaks: false)
    }

    public static func encodeMessageQuoted(_ value: String) throws -> Data {
        try encodeQuoted(value, allowsLineBreaks: true)
    }

    private static func encodeQuoted(
        _ value: String,
        allowsLineBreaks: Bool
    ) throws -> Data {
        var bytes = Data([0x22])
        for scalar in value.unicodeScalars {
            if scalar.value == 0
                || (!allowsLineBreaks && (scalar.value == 10 || scalar.value == 13)) {
                throw SieveStringEncodingError.unsupportedControlCharacter
            }
            if scalar == "\"" || scalar == "\\" {
                bytes.append(0x5c)
            }
            bytes.append(contentsOf: String(scalar).utf8)
        }
        bytes.append(0x22)
        return bytes
    }
}
