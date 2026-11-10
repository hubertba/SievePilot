public struct ManageSieveLimits: Equatable, Sendable {
    public static let production = ManageSieveLimits()

    /// Maximum logical-line non-literal syntax bytes, excluding CRLF delimiters and literal bodies.
    /// Literal headers count toward this limit; aggregate response accounting includes all framing.
    public let maximumLineLength: Int
    public let maximumLiteralLength: Int
    public let maximumAggregateResponseLength: Int
    public let maximumLineCount: Int

    public init(
        maximumLineLength: Int = 8 * 1024,
        maximumLiteralLength: Int = 10 * 1024 * 1024,
        maximumAggregateResponseLength: Int = 16 * 1024 * 1024,
        maximumLineCount: Int = 256
    ) {
        precondition(maximumLineLength >= 0)
        precondition(maximumLiteralLength >= 0)
        precondition(maximumAggregateResponseLength >= 0)
        precondition(maximumLineCount >= 0)

        self.maximumLineLength = maximumLineLength
        self.maximumLiteralLength = maximumLiteralLength
        self.maximumAggregateResponseLength = maximumAggregateResponseLength
        self.maximumLineCount = maximumLineCount
    }
}
