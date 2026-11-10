// Payloads are local metadata only; never add server text, credentials, challenges, or script bodies.
public enum ManageSieveLogEvent: Equatable, Sendable {
    case connected
    case encrypted
    case authenticationStarted(mechanism: String)
    case authenticationRejected
    case authenticated
    case timedOut
    case cancelled
    case closed
}

public protocol ManageSieveLogger: Sendable {
    func record(_ event: ManageSieveLogEvent)
}
