public protocol ManageSieveClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ManageSieveTimeoutPolicy: Equatable, Sendable {
    public let connect: Duration
    public let startTLS: Duration
    public let authentication: Duration
    public let command: Duration

    public init(connect: Duration, startTLS: Duration, authentication: Duration, command: Duration) {
        self.connect = connect
        self.startTLS = startTLS
        self.authentication = authentication
        self.command = command
    }
}
