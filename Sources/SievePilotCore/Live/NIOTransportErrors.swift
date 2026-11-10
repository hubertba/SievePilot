public enum NIOTransportError: Error, Equatable, Sendable {
    case invalidState
    case invalidReadSize
    case connectionFailed
    case readFailed
    case writeFailed
    case closed
    case tlsUnsupported
}
