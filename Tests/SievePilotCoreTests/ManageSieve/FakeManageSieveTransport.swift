import Foundation
@testable import SievePilotCore

actor FakeManageSieveTransport: ManageSieveTransport {
    enum Step {
        case connect
        case suspendConnect
        case read(Data)
        case slowRead
        case write(Data)
        case upgrade(ManageSieveTLSIdentityRequest)
        case failure
    }

    private var steps: [Step]
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private(set) var writes: [Data] = []
    private(set) var readCount = 0
    private(set) var closeCount = 0
    private(set) var upgradeCount = 0
    private(set) var slowReadStarted = false
    private(set) var violations: [String] = []

    init(_ steps: [Step]) { self.steps = steps }

    func connect() async throws {
        switch take() {
        case .connect: break
        case .suspendConnect:
            await withCheckedContinuation { continuation in
                connectContinuation = continuation
            }
        case .failure: throw FakeError.injected
        default: throw FakeError.unexpectedStep
        }
    }

    func resumeConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    var isConnectSuspended: Bool { connectContinuation != nil }

    func read(maxBytes: Int) async throws -> Data {
        readCount += 1
        switch take() {
        case let .read(data):
            if data.count > maxBytes { violations.append("oversized read") }
            return data
        case .slowRead:
            slowReadStarted = true
            try await Task.sleep(for: .seconds(60))
            return Data()
        case .failure: throw FakeError.injected
        default: throw FakeError.unexpectedStep
        }
    }

    func write(_ data: Data) throws {
        writes.append(data)
        guard case let .write(expected) = take(), data == expected else {
            throw FakeError.unexpectedStep
        }
    }

    func upgradeToTLS(identity: ManageSieveTLSIdentityRequest) throws {
        upgradeCount += 1
        switch take() {
        case let .upgrade(expected) where expected == identity: break
        case .failure: throw FakeError.injected
        default: throw FakeError.unexpectedStep
        }
    }

    func close() {
        closeCount += 1
        // A real transport must release pending connect/read/write/upgrade operations on close.
        resumeConnect()
    }

    func assertComplete() -> Bool { steps.isEmpty && violations.isEmpty }

    private func take() -> Step {
        guard !steps.isEmpty else {
            violations.append("unexpected operation")
            return .failure
        }
        return steps.removeFirst()
    }
}

enum FakeError: Error { case injected, unexpectedStep }

struct FakeManageSieveClock: ManageSieveClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct ImmediateManageSieveClock: ManageSieveClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct FakeManageSieveLogger: ManageSieveLogger {
    func record(_ event: ManageSieveLogEvent) {}
}

final class RecordingManageSieveLogger: ManageSieveLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ManageSieveLogEvent] = []

    func record(_ event: ManageSieveLogEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [ManageSieveLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
