import Foundation

public enum ExpiryResolutionError: Error, Equatable, Sendable {
    case incompleteLocalTime
    case nonexistentLocalTime
    case repeatedLocalTimeRequiresOffset
    case invalidRepeatedTimeOffset
}

public enum ExpiryResolver {
    public static func resolve(
        localComponents: DateComponents,
        timeZone: TimeZone,
        repeatedTimeOffset: Int?
    ) throws -> ResolvedExpiry {
        guard
            let year = localComponents.year,
            let month = localComponents.month,
            let day = localComponents.day,
            let hour = localComponents.hour,
            let minute = localComponents.minute
        else {
            throw ExpiryResolutionError.incompleteLocalTime
        }

        let second = localComponents.second ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let dayStartComponents = DateComponents(year: year, month: month, day: day)
        guard let dayStart = calendar.date(from: dayStartComponents) else {
            throw ExpiryResolutionError.nonexistentLocalTime
        }

        let match = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        let searchStart = dayStart.addingTimeInterval(-1)
        let first = calendar.nextDate(
            after: searchStart,
            matching: match,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        let last = calendar.nextDate(
            after: searchStart,
            matching: match,
            matchingPolicy: .strict,
            repeatedTimePolicy: .last,
            direction: .forward
        )

        guard let first, let last else {
            throw ExpiryResolutionError.nonexistentLocalTime
        }

        let selected: Date
        if first == last {
            if let repeatedTimeOffset,
               timeZone.secondsFromGMT(for: first) != repeatedTimeOffset {
                throw ExpiryResolutionError.invalidRepeatedTimeOffset
            }
            selected = first
        } else {
            guard let repeatedTimeOffset else {
                throw ExpiryResolutionError.repeatedLocalTimeRequiresOffset
            }
            let candidates = [first, last]
            guard let matching = candidates.first(where: {
                timeZone.secondsFromGMT(for: $0) == repeatedTimeOffset
            }) else {
                throw ExpiryResolutionError.invalidRepeatedTimeOffset
            }
            selected = matching
        }

        return ResolvedExpiry(
            instant: selected,
            timeZoneIdentifier: timeZone.identifier,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: selected)
        )
    }
}
