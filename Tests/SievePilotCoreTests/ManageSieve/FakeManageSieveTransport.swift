import Foundation
@testable import SievePilotCore

actor FakeManageSieveTransport: ManageSieveTransport {
    enum Step {
        case connect
        case suspendConnect
        case read(Data)
        case slowRead
        case suspendRead
        case suspendWrite(Data)
        case suspendUpgrade(ManageSieveTLSIdentityRequest)
        case write(Data)
        case upgrade(ManageSieveTLSIdentityRequest)
        case failure
        case tlsFailure(NIOTransportError)
    }

    enum Suspension: Sendable { case read, write, upgrade }
    private(set) var suspension: Suspension?
    private var continuation: CheckedContinuation<Data, Error>?
    private var steps: [Step]
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private(set) var writes: [Data] = []
    private(set) var readCount = 0
    private(set) var readLimits: [Int] = []
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
        readLimits.append(maxBytes)
        switch take() {
        case let .read(data):
            if data.count > maxBytes { steps.insert(.read(Data(data.dropFirst(maxBytes))), at: 0) }
            return Data(data.prefix(maxBytes))
        case .suspendRead:
            return try await suspend(.read)
        case .slowRead:
            slowReadStarted = true
            try await Task.sleep(for: .seconds(60))
            return Data()
        case .failure: throw FakeError.injected
        default: throw FakeError.unexpectedStep
        }
    }

    func write(_ data: Data) async throws {
        writes.append(data)
        switch take() {
        case let .write(expected) where data == expected: break
        case let .suspendWrite(expected) where data == expected: _ = try await suspend(.write)
        default: throw FakeError.unexpectedStep
        }
    }

    func upgradeToTLS(identity: ManageSieveTLSIdentityRequest) async throws {
        upgradeCount += 1
        switch take() {
        case let .upgrade(expected) where expected == identity: break
        case let .suspendUpgrade(expected) where expected == identity: _ = try await suspend(.upgrade)
        case .failure: throw FakeError.injected
        case .tlsFailure(let error): throw error
        default: throw FakeError.unexpectedStep
        }
    }

    func close() {
        closeCount += 1
        // A real transport must release pending connect/read/write/upgrade operations on close.
        resumeConnect()
        resumeSuspension(.failure(FakeError.injected))
    }

    private func suspend(_ stage: Suspension) async throws -> Data {
        suspension = stage
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resumeSuspension(_ result: Result<Data, Error> = .success(Data())) {
        let pending = continuation
        continuation = nil
        suspension = nil
        pending?.resume(with: result)
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

// Keeps cancelled sleepers until fired to exercise late timer completion deterministically.
actor ManualManageSieveClock: ManageSieveClock {
    private var sleepers: [CheckedContinuation<Void, Error>] = []
    private(set) var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { sleepers.append($0) }
    }

    var pendingCount: Int { sleepers.count }

    func fireNext() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume()
    }

    func fire() {
        let pending = sleepers
        sleepers.removeAll()
        for sleeper in pending { sleeper.resume() }
    }
}
