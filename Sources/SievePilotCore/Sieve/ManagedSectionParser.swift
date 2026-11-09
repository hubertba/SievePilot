import Foundation

public struct ManagedSections: Equatable, Sendable {
    public let metadata: Range<Int>?
    public let requirements: Range<Int>?
    public let outOfOfficeRule: Range<Int>?

    public init(
        metadata: Range<Int>? = nil,
        requirements: Range<Int>? = nil,
        outOfOfficeRule: Range<Int>? = nil
    ) {
        self.metadata = metadata
        self.requirements = requirements
        self.outOfOfficeRule = outOfOfficeRule
    }

    var orderedRanges: [Range<Int>] {
        [metadata, requirements, outOfOfficeRule].compactMap { $0 }
    }
}

public enum ManagedSectionError: Error, Equatable, Sendable {
    case partialMarker
    case duplicateSection
    case nestedSection
    case unknownVersion
    case misplacedSection
    case markerInsideGeneratedSection
}

public enum ManagedSectionParser {
    public static func parse(_ script: Data, preamble: SievePreamble) throws -> ManagedSections {
        let scanner = MarkerScanner(data: script)
        let events = try scanner.events()
        guard !events.isEmpty else { return ManagedSections() }

        var open: (kind: SectionKind, start: Int)?
        var completed: [SectionKind: Range<Int>] = [:]

        for event in events {
            switch event.boundary {
            case .begin:
                if open != nil { throw ManagedSectionError.nestedSection }
                if completed[event.kind] != nil { throw ManagedSectionError.duplicateSection }
                open = (event.kind, event.range.lowerBound)
            case .end:
                guard let current = open else { throw ManagedSectionError.partialMarker }
                guard current.kind == event.kind else { throw ManagedSectionError.nestedSection }
                if completed[event.kind] != nil { throw ManagedSectionError.duplicateSection }
                completed[event.kind] = current.start..<event.range.upperBound
                open = nil
            }
        }

        guard open == nil else { throw ManagedSectionError.partialMarker }
        guard let metadata = completed[.metadata] else {
            throw ManagedSectionError.partialMarker
        }

        let requirements = completed[.requirements]
        let rule = completed[.outOfOfficeRule]
        guard (requirements == nil) == (rule == nil) else {
            throw ManagedSectionError.partialMarker
        }

        let sections = ManagedSections(
            metadata: metadata,
            requirements: requirements,
            outOfOfficeRule: rule
        )
        let ranges = sections.orderedRanges
        guard ranges.first?.lowerBound == preamble.insertionOffset else {
            throw ManagedSectionError.misplacedSection
        }
        for pair in zip(ranges, ranges.dropFirst()) {
            guard scanner.isWhitespaceOnly(pair.0.upperBound..<pair.1.lowerBound) else {
                throw ManagedSectionError.misplacedSection
            }
        }
        guard ranges == ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) else {
            throw ManagedSectionError.misplacedSection
        }

        return sections
    }
}

private enum SectionKind: Hashable {
    case metadata
    case requirements
    case outOfOfficeRule
}

private enum MarkerBoundary {
    case begin
    case end
}

private struct MarkerEvent {
    let kind: SectionKind
    let boundary: MarkerBoundary
    let range: Range<Int>
}

private struct MarkerScanner {
    let bytes: [UInt8]
    let lexer: SieveByteLexer

    init(data: Data) {
        bytes = Array(data)
        lexer = SieveByteLexer(data: data)
    }

    func events() throws -> [MarkerEvent] {
        var result: [MarkerEvent] = []
        var index = 0

        while index < bytes.count {
            if bytes[index] == 0x22 {
                index = try lexer.skipQuotedString(from: index)
                continue
            }
            if lexer.hasASCII("text:", at: index), isTokenBoundary(before: index) {
                index = try lexer.skipMultilineLiteral(from: index)
                continue
            }
            if bytes[index] == 0x2f,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x2a {
                guard let end = blockCommentEnd(from: index + 2) else {
                    throw ManagedSectionError.markerInsideGeneratedSection
                }
                index = end
                continue
            }
            if bytes[index] == 0x23 {
                let line = lineRange(containing: index)
                if isWhitespaceOnly(line.lowerBound..<index) {
                    let textEnd = lineTextEnd(line)
                    let text = String(decoding: bytes[index..<textEnd], as: UTF8.self)
                    if let marker = marker(for: text) {
                        result.append(MarkerEvent(kind: marker.0, boundary: marker.1, range: line))
                    } else if text.hasPrefix("# BEGIN SIEVEPILOT")
                                || text.hasPrefix("# END SIEVEPILOT") {
                        throw ManagedSectionError.unknownVersion
                    }
                }
                index = line.upperBound
                continue
            }
            index += 1
        }

        return result
    }

    func isWhitespaceOnly(_ range: Range<Int>) -> Bool {
        range.allSatisfy { index in
            switch bytes[index] {
            case 0x09, 0x0a, 0x0c, 0x0d, 0x20: true
            default: false
            }
        }
    }

    private func marker(for text: String) -> (SectionKind, MarkerBoundary)? {
        switch text {
        case "# BEGIN SIEVEPILOT METADATA v1": (.metadata, .begin)
        case "# END SIEVEPILOT METADATA v1": (.metadata, .end)
        case "# BEGIN SIEVEPILOT REQUIREMENTS v1": (.requirements, .begin)
        case "# END SIEVEPILOT REQUIREMENTS v1": (.requirements, .end)
        case "# BEGIN SIEVEPILOT RULE v1: out-of-office": (.outOfOfficeRule, .begin)
        case "# END SIEVEPILOT RULE v1: out-of-office": (.outOfOfficeRule, .end)
        default: nil
        }
    }

    private func lineRange(containing index: Int) -> Range<Int> {
        var start = index
        while start > 0, bytes[start - 1] != 0x0a { start -= 1 }
        var end = index
        while end < bytes.count, bytes[end] != 0x0a { end += 1 }
        if end < bytes.count { end += 1 }
        return start..<end
    }

    private func lineTextEnd(_ range: Range<Int>) -> Int {
        var end = range.upperBound
        if end > range.lowerBound, bytes[end - 1] == 0x0a { end -= 1 }
        if end > range.lowerBound, bytes[end - 1] == 0x0d { end -= 1 }
        return end
    }

    private func blockCommentEnd(from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x2a, bytes[index + 1] == 0x2f { return index + 2 }
            index += 1
        }
        return nil
    }

    private func isTokenBoundary(before index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = bytes[index - 1]
        return !((0x41...0x5a).contains(previous)
            || (0x61...0x7a).contains(previous)
            || (0x30...0x39).contains(previous)
            || previous == 0x5f)
    }
}
