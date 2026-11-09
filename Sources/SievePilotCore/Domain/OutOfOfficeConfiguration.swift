import Foundation

public struct ResolvedExpiry: Codable, Equatable, Sendable {
    public let instant: Date
    public let timeZoneIdentifier: String
    public let utcOffsetSeconds: Int

    public init(instant: Date, timeZoneIdentifier: String, utcOffsetSeconds: Int) {
        self.instant = instant
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}

public enum OutOfOfficeConfigurationError: Error, Equatable, Sendable {
    case emptyMessage
}

public struct OutOfOfficeConfiguration: Codable, Equatable, Sendable {
    public let emailAddress: String
    public let subject: String?
    public let message: String
    public let expiry: ResolvedExpiry

    public init(
        emailAddress: String,
        subject: String?,
        message: String,
        expiry: ResolvedExpiry
    ) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OutOfOfficeConfigurationError.emptyMessage
        }

        self.emailAddress = emailAddress
        self.subject = subject.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        self.message = message
        self.expiry = expiry
    }
}
