public enum ManageSieveLogEvent: Equatable, Sendable {
    case connected
    case encrypted
    case closed
}

public protocol ManageSieveLogger: Sendable {
    func record(_ event: ManageSieveLogEvent)
}
