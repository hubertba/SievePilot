import Foundation
import Testing
@testable import SievePilotCore

@Suite struct ExpiryResolverTests {
    private let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    @Test func testRejectsNonexistentWarsawLocalTime() throws {
        let transition = try transitionWithOffsetIncrease()
        let componentsAfterTransition = localComponents(for: transition.addingTimeInterval(60))
        var nonexistent = componentsAfterTransition
        nonexistent.hour = (componentsAfterTransition.hour ?? 3) - 1
        nonexistent.minute = 30
        nonexistent.second = 0

        #expect(throws: ExpiryResolutionError.nonexistentLocalTime) {
            try ExpiryResolver.resolve(
                localComponents: nonexistent,
                timeZone: warsaw,
                repeatedTimeOffset: nil
            )
        }
    }

    @Test func testRequiresOffsetForRepeatedWarsawLocalTime() throws {
        let repeated = try repeatedLocalComponents()

        #expect(throws: ExpiryResolutionError.repeatedLocalTimeRequiresOffset) {
            try ExpiryResolver.resolve(
                localComponents: repeated,
                timeZone: warsaw,
                repeatedTimeOffset: nil
            )
        }
    }

    @Test func testResolvesSelectedRepeatedTimeOffset() throws {
        let repeated = try repeatedLocalComponents()
        let candidates = try repeatedCandidates(for: repeated)
        let selectedOffset = warsaw.secondsFromGMT(for: candidates.last)

        let resolved = try ExpiryResolver.resolve(
            localComponents: repeated,
            timeZone: warsaw,
            repeatedTimeOffset: selectedOffset
        )

        #expect(resolved.instant == candidates.last)
        #expect(resolved.utcOffsetSeconds == selectedOffset)
        #expect(resolved.timeZoneIdentifier == "Europe/Warsaw")
    }

    private func transitionWithOffsetIncrease() throws -> Date {
        var cursor = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        for _ in 0..<4 {
            guard let transition = warsaw.nextDaylightSavingTimeTransition(after: cursor) else {
                break
            }
            let before = warsaw.secondsFromGMT(for: transition.addingTimeInterval(-1))
            let after = warsaw.secondsFromGMT(for: transition.addingTimeInterval(1))
            if after > before { return transition }
            cursor = transition.addingTimeInterval(1)
        }
        throw TestError.transitionNotFound
    }

    private func transitionWithOffsetDecrease() throws -> Date {
        var cursor = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        for _ in 0..<4 {
            guard let transition = warsaw.nextDaylightSavingTimeTransition(after: cursor) else {
                break
            }
            let before = warsaw.secondsFromGMT(for: transition.addingTimeInterval(-1))
            let after = warsaw.secondsFromGMT(for: transition.addingTimeInterval(1))
            if after < before { return transition }
            cursor = transition.addingTimeInterval(1)
        }
        throw TestError.transitionNotFound
    }

    private func repeatedLocalComponents() throws -> DateComponents {
        let transition = try transitionWithOffsetDecrease()
        var components = localComponents(for: transition.addingTimeInterval(30 * 60))
        components.second = 0
        return components
    }

    private func repeatedCandidates(for components: DateComponents) throws -> (first: Date, last: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = warsaw
        let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day))!
        let match = DateComponents(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            second: components.second
        )
        guard
            let first = calendar.nextDate(
                after: start.addingTimeInterval(-1),
                matching: match,
                matchingPolicy: .strict,
                repeatedTimePolicy: .first,
                direction: .forward
            ),
            let last = calendar.nextDate(
                after: start.addingTimeInterval(-1),
                matching: match,
                matchingPolicy: .strict,
                repeatedTimePolicy: .last,
                direction: .forward
            ),
            first != last
        else {
            throw TestError.repeatedCandidatesNotFound
        }
        return (first, last)
    }

    private func localComponents(for date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = warsaw
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private enum TestError: Error {
        case transitionNotFound
        case repeatedCandidatesNotFound
    }
}
