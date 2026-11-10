public enum ManageSieveLogEvent: Equatable, Sendable {
    case connected
    case encrypted
    case authenticationStarted(mechanism: String)
    case authenticationRejected
    case authenticated
    case closed
}

public protocol ManageSieveLogger: Sendable {
    func record(_ event: ManageSieveLogEvent)
}
