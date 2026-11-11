import Foundation
import dnssd

public struct DNSServiceResolver: SieveSRVResolving {
    private let timeout: TimeInterval
    private let maximumRecords: Int
    private let maximumRDataBytes: Int
    private let makeQuery: @Sendable () -> any DNSServiceQuery

    public init(timeout: TimeInterval = 5, maximumRecords: Int = 256, maximumRDataBytes: Int = 65_536) {
        self.init(timeout: timeout, maximumRecords: maximumRecords, maximumRDataBytes: maximumRDataBytes) {
            SystemDNSServiceQuery()
        }
    }

    internal init(timeout: TimeInterval, maximumRecords: Int, maximumRDataBytes: Int,
                  makeQuery: @escaping @Sendable () -> any DNSServiceQuery) {
        self.timeout = timeout
        self.maximumRecords = maximumRecords
        self.maximumRDataBytes = maximumRDataBytes
        self.makeQuery = makeQuery
    }

    public func records(for name: String) async throws -> [SieveSRVRecord] {
        try Task.checkCancellation()
        let operation = DNSServiceOperation(name: name, timeout: timeout, maximumRecords: maximumRecords,
                                            maximumRDataBytes: maximumRDataBytes, makeQuery: makeQuery)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.queue.async { operation.start(continuation) }
            }
        } onCancel: {
            // DNSServiceRefDeallocate must run on the callback queue, never the cancelling thread.
            operation.queue.async { operation.finish(.failure(CancellationError())) }
        }
    }
}

internal struct DNSServiceReply: Sendable {
    let add: Bool
    let moreComing: Bool
    let errorCode: Int32
    let recordType: UInt16
    let recordClass: UInt16
    let rdata: [UInt8]
}

// start/cancel and all callbacks run on the supplied serial queue. start never calls back inline;
// cancel releases its callback and prevents further system callbacks before returning.
internal protocol DNSServiceQuery: AnyObject {
    func start(name: String, queue: DispatchQueue, callback: @escaping (DNSServiceReply) -> Void) throws
    func cancel()
}

// The lock owns every mutable field. The private serial queue additionally confines all DNS-SD
// calls, including destruction, so an unretained C callback context cannot race deallocation.
private final class DNSServiceOperation: @unchecked Sendable {
    let queue = DispatchQueue(label: "SievePilot.DNSService.query")
    private let lock = NSLock()
    private let name: String
    private let timeout: TimeInterval
    private let maximumRecords: Int
    private let maximumRDataBytes: Int
    private let makeQuery: @Sendable () -> any DNSServiceQuery
    private var continuation: CheckedContinuation<[SieveSRVRecord], Error>?
    private var terminalResult: Result<[SieveSRVRecord], Error>?
    private var query: (any DNSServiceQuery)?
    private var timer: DispatchSourceTimer?
    private var records: [SieveSRVRecord] = []
    private var receivedBytes = 0

    init(name: String, timeout: TimeInterval, maximumRecords: Int, maximumRDataBytes: Int,
         makeQuery: @escaping @Sendable () -> any DNSServiceQuery) {
        self.name = name
        self.timeout = timeout
        self.maximumRecords = maximumRecords
        self.maximumRDataBytes = maximumRDataBytes
        self.makeQuery = makeQuery
    }

    func start(_ continuation: CheckedContinuation<[SieveSRVRecord], Error>) {
        lock.lock(); defer { lock.unlock() }
        // Cancellation can win before the continuation is installed.
        if let terminalResult { continuation.resume(with: terminalResult); return }
        self.continuation = continuation
        let nanoseconds = timeout * 1_000_000_000
        guard timeout.isFinite, nanoseconds >= 1, nanoseconds < Double(UInt64.max),
              maximumRecords > 0, maximumRDataBytes > 0, !name.isEmpty, !name.utf8.contains(0) else {
            finishLocked(.failure(SieveServiceDiscoveryError.invalidConfiguration)); return
        }
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(nanoseconds))
        guard !overflow else { finishLocked(.failure(SieveServiceDiscoveryError.invalidConfiguration)); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [self] in finish(.failure(SieveServiceDiscoveryError.timedOut)) }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
        timer.resume()
        let query = makeQuery()
        self.query = query
        do { try query.start(name: name, queue: queue) { [self] reply in receive(reply) } }
        catch { finishLocked(.failure(error)) }
    }

    private func receive(_ reply: DNSServiceReply) {
        lock.lock(); defer { lock.unlock() }
        guard terminalResult == nil else { return }
        do {
            guard reply.errorCode == 0 else { throw SieveServiceDiscoveryError.dnsService(reply.errorCode) }
            let (bytes, overflow) = receivedBytes.addingReportingOverflow(reply.rdata.count)
            guard !overflow, bytes <= maximumRDataBytes else { throw SieveServiceDiscoveryError.responseLimitExceeded }
            receivedBytes = bytes
            guard reply.recordType == 33, reply.recordClass == 1 else { throw SieveServiceDiscoveryError.invalidRecord }
            let record = try Self.parse(reply.rdata)
            // Equality is canonical. Byte accounting includes duplicates and absent removals.
            if reply.add {
                if !records.contains(record) {
                    guard records.count < maximumRecords else { throw SieveServiceDiscoveryError.responseLimitExceeded }
                    records.append(record)
                }
            } else {
                records.removeAll { $0 == record }
            }
            if !reply.moreComing { finishLocked(.success(records.sorted(by: SieveSRVRecord.canonicalOrder))) }
        } catch { finishLocked(.failure(error)) }
    }

    func finish(_ result: Result<[SieveSRVRecord], Error>) {
        lock.lock(); defer { lock.unlock() }
        finishLocked(result)
    }

    private func finishLocked(_ result: Result<[SieveSRVRecord], Error>) {
        guard terminalResult == nil else { return }
        terminalResult = result
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        query?.cancel()
        query = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func parse(_ bytes: [UInt8]) throws -> SieveSRVRecord {
        guard bytes.count >= 7 else { throw SieveServiceDiscoveryError.invalidRecord }
        func uint16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        var offset = 6
        var labels: [String] = []
        while true {
            guard offset < bytes.count else { throw SieveServiceDiscoveryError.invalidRecord }
            let count = Int(bytes[offset]); offset += 1
            if count == 0 { break }
            // SRV target compression is prohibited; also reject extended labels and truncation.
            guard count <= 63, count <= bytes.count - offset,
                  let label = String(bytes: bytes[offset..<(offset + count)], encoding: .ascii),
                  !label.contains(".") else { throw SieveServiceDiscoveryError.invalidRecord }
            labels.append(label)
            offset += count
            guard offset - 6 <= 254 else { throw SieveServiceDiscoveryError.invalidRecord }
        }
        guard offset == bytes.count, offset - 6 <= 255 else { throw SieveServiceDiscoveryError.invalidRecord }
        let target = labels.isEmpty ? "." : labels.joined(separator: ".")
        return try SieveSRVRecord(priority: uint16(0), weight: uint16(2), port: uint16(4), target: target).normalized()
    }
}

internal protocol DNSServiceClient: Sendable {
    func query(name: String, callback: @escaping DNSServiceQueryRecordReply, context: UnsafeMutableRawPointer) -> (status: Int32, reference: DNSServiceRef?)
    func setDispatchQueue(reference: DNSServiceRef, queue: DispatchQueue) -> Int32
    func deallocate(reference: DNSServiceRef)
}

private struct SystemDNSServiceClient: DNSServiceClient {
    func query(name: String, callback: @escaping DNSServiceQueryRecordReply, context: UnsafeMutableRawPointer) -> (status: Int32, reference: DNSServiceRef?) {
        var reference: DNSServiceRef?
        let status = DNSServiceQueryRecord(&reference, 0, 0, name, UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN), callback, context)
        return (status, reference)
    }
    func setDispatchQueue(reference: DNSServiceRef, queue: DispatchQueue) -> Int32 {
        DNSServiceSetDispatchQueue(reference, queue)
    }
    func deallocate(reference: DNSServiceRef) { DNSServiceRefDeallocate(reference) }
}

internal final class SystemDNSServiceQuery: DNSServiceQuery {
    private let client: any DNSServiceClient
    private var reference: DNSServiceRef?
    private var callback: ((DNSServiceReply) -> Void)?

    init() { self.client = SystemDNSServiceClient() }
    internal init(client: any DNSServiceClient) { self.client = client }

    func start(name: String, queue: DispatchQueue, callback: @escaping (DNSServiceReply) -> Void) throws {
        self.callback = callback
        let result = client.query(name: name, callback: { _, flags, _, error, _, type, recordClass, length, data, _, context in
            guard let context else { return }
            let owner = Unmanaged<SystemDNSServiceQuery>.fromOpaque(context).takeUnretainedValue()
            // On error every other C callback argument is undefined; do not dereference RDATA.
            if error != kDNSServiceErr_NoError {
                owner.callback?(DNSServiceReply(add: false, moreComing: false, errorCode: error, recordType: 0, recordClass: 0, rdata: []))
                return
            }
            let bytes = data.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(length))) } ?? []
            owner.callback?(DNSServiceReply(add: flags & UInt32(kDNSServiceFlagsAdd) != 0,
                                            moreComing: flags & UInt32(kDNSServiceFlagsMoreComing) != 0,
                                            errorCode: 0, recordType: type, recordClass: recordClass, rdata: bytes))
        }, context: Unmanaged.passUnretained(self).toOpaque())
        guard result.status == kDNSServiceErr_NoError else { throw SieveServiceDiscoveryError.dnsService(result.status) }
        reference = result.reference
        guard let reference else { throw SieveServiceDiscoveryError.invalidRecord }
        let dispatchStatus = client.setDispatchQueue(reference: reference, queue: queue)
        guard dispatchStatus == kDNSServiceErr_NoError else { throw SieveServiceDiscoveryError.dnsService(dispatchStatus) }
    }

    func cancel() {
        if let reference {
            self.reference = nil
            client.deallocate(reference: reference)
        }
        callback = nil
    }
}
