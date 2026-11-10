public enum NIOTransportError: Error, Equatable, Sendable {
    case invalidState
    case invalidReadSize
    case connectionFailed
    case readFailed
    case inboundOverflow
    case writeFailed
    case closed
    case tlsUnsupported
}
