import Foundation

public enum ManageSieveStatus: Equatable, Sendable {
    case ok
    case no
    case bye
}

public enum ManageSieveInterpretationError: Error, Equatable, Sendable {
    case malformedStatus
    case missingTerminalStatus
    case multipleTerminalStatuses
    case capabilityResponseRejected(ManageSieveStatus)
    case malformedCapability
    case duplicateSingletonCapability(String)
    case missingAuthoritativeCapability(String)
}

public struct ManageSieveStatusResponse: Equatable, Sendable {
    public let status: ManageSieveStatus
    public let responseCode: ManageSieveToken?
    public let message: Data?

    public init(line: ManageSieveWireLine) throws {
        guard let first = line.tokens.first,
              case let .atom(keyword) = first,
              let status = ManageSieveStatus(keyword: keyword)
        else {
            throw ManageSieveInterpretationError.malformedStatus
        }

        let remaining = Array(line.tokens.dropFirst())
        var responseCode: ManageSieveToken? = nil
        var message: Data? = nil

        if remaining.isEmpty {
            responseCode = nil
            message = nil
        } else if remaining.count == 1 {
            switch remaining[0] {
            case let .list(codeTokens):
                guard Self.isResponseCode(codeTokens) else {
                    throw ManageSieveInterpretationError.malformedStatus
                }
                responseCode = .list(codeTokens)
            case let .string(value):
                message = value
            default:
                throw ManageSieveInterpretationError.malformedStatus
            }
        } else if remaining.count == 2,
                  case let .list(codeTokens) = remaining[0],
                  case let .string(value) = remaining[1],
                  Self.isResponseCode(codeTokens) {
            responseCode = .list(codeTokens)
            message = value
        } else {
            throw ManageSieveInterpretationError.malformedStatus
        }

        self.status = status
        self.responseCode = responseCode
        self.message = message
    }

    private static func isResponseCode(_ tokens: [ManageSieveToken]) -> Bool {
        guard case .atom? = tokens.first else { return false }
        return true
    }
}

public struct ManageSieveCommandResponse: Equatable, Sendable {
    public let dataLines: [ManageSieveWireLine]
    public let status: ManageSieveStatusResponse

    public init(lines: [ManageSieveWireLine]) throws {
        guard let terminalLine = lines.last,
              terminalLine.startsWithTerminalStatus
        else {
            throw ManageSieveInterpretationError.missingTerminalStatus
        }

        let dataLines = Array(lines.dropLast())
        guard !dataLines.contains(where: \.startsWithTerminalStatus) else {
            throw ManageSieveInterpretationError.multipleTerminalStatuses
        }

        self.dataLines = dataLines
        status = try ManageSieveStatusResponse(line: terminalLine)
    }
}

private extension ManageSieveStatus {
    init?(keyword: String) {
        switch keyword.uppercased() {
        case "OK": self = .ok
        case "NO": self = .no
        case "BYE": self = .bye
        default: return nil
        }
    }
}

private extension ManageSieveWireLine {
    var startsWithTerminalStatus: Bool {
        guard case let .atom(keyword)? = tokens.first else { return false }
        return ManageSieveStatus(keyword: keyword) != nil
    }
}
