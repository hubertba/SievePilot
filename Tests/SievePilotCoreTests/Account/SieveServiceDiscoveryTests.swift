import Foundation
import dnssd
import XCTest
@testable import SievePilotCore

private actor RecordingSRVResolver: SieveSRVResolving {
    let answer: [SieveSRVRecord]
    var names: [String] = []
    init(_ answer: [SieveSRVRecord]) { self.answer = answer }
    func records(for name: String) async throws -> [SieveSRVRecord] {
        names.append(name)
        return answer
    }
}

private final class FixedSieveRandom: SieveRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bounds: [UInt64] = []
    let draw: UInt64
    init(_ draw: UInt64) { self.draw = draw }
    func next(upperBound: UInt64) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        bounds.append(upperBound)
        return draw
    }
    var requestedBounds: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return bounds
    }
}

// All mutable query state is confined to the resolver's supplied serial queue.
private final class ScriptedDNSQuery: DNSServiceQuery {
    let script: [DNSServiceReply]
    let startError: SieveServiceDiscoveryError?
    let onStart: (() -> Void)?
    let onCancel: () -> Void
    private var callback: ((DNSServiceReply) -> Void)?
    init(_ script: [DNSServiceReply], startError: SieveServiceDiscoveryError? = nil,
         onStart: (() -> Void)? = nil, onCancel: @escaping () -> Void) {
        self.script = script; self.startError = startError
        self.onStart = onStart; self.onCancel = onCancel
    }
    func start(name: String, queue: DispatchQueue, callback: @escaping (DNSServiceReply) -> Void) throws {
        self.callback = callback
        onStart?()
        if let startError { throw startError }
        queue.async { [self] in
            // Deliberately deliver late replies too, to test the terminal guard.
            for reply in script { callback(reply) }
        }
    }
    func cancel() { callback = nil; onCancel() }
}

private final class StubDNSServiceClient: DNSServiceClient, @unchecked Sendable {
    enum Reply {
        case srv
        case error(Int32)
        case cnameThenSRV
    }

    private let lock = NSLock()
    private var deallocations = 0
    private var queries = 0
    private var queryFlags: UInt32 = 0
    let queryStatus: Int32
    let dispatchStatus: Int32
    let reply: Reply
    let sendsReply: Bool
    let onStart: (@Sendable () -> Void)?
    init(queryStatus: Int32 = 0, dispatchStatus: Int32 = 0, callbackError: Int32 = 0,
         reply: Reply? = nil, sendsReply: Bool = true, onStart: (@Sendable () -> Void)? = nil) {
        self.queryStatus = queryStatus; self.dispatchStatus = dispatchStatus
        self.reply = reply ?? (callbackError == 0 ? .srv : .error(callbackError))
        self.sendsReply = sendsReply; self.onStart = onStart
    }
    private var callback: DNSServiceQueryRecordReply?
    private var context: UnsafeMutableRawPointer?
    func query(name: String, flags: UInt32, callback: @escaping DNSServiceQueryRecordReply, context: UnsafeMutableRawPointer) -> (status: Int32, reference: DNSServiceRef?) {
        lock.lock(); defer { lock.unlock() }
        queries += 1
        queryFlags = flags
        self.callback = callback; self.context = context
        return (queryStatus, queryStatus == 0 ? OpaquePointer(bitPattern: 1)! : nil)
    }
    func setDispatchQueue(reference: DNSServiceRef, queue: DispatchQueue) -> Int32 {
        if dispatchStatus != 0 { return dispatchStatus }
        onStart?()
        guard sendsReply else { return 0 }
        queue.async { [self] in
            lock.lock()
            let callback = self.callback, context = self.context
            lock.unlock()
            let bytes: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x10, 0x5e, 4, 77, 65, 73, 76, 7, 101, 120, 97, 109, 112, 108, 101, 3, 111, 114, 103, 0]
            switch reply {
            case .error(let error):
                // All arguments except the context/error are undefined on failure.
                callback?(reference, UInt32.max, 0, error, nil, 0, 0, UInt16.max, UnsafeRawPointer(bitPattern: 1), 0, context)
            case .srv:
                bytes.withUnsafeBytes {
                    callback?(reference, UInt32(kDNSServiceFlagsAdd), 0, 0, nil, 33, 1, UInt16($0.count), $0.baseAddress, 0, context)
                }
            case .cnameThenSRV:
                let cname: [UInt8] = [4, 77, 65, 73, 76, 7, 101, 120, 97, 109, 112, 108, 101, 3, 111, 114, 103, 0]
                cname.withUnsafeBytes {
                    callback?(reference, UInt32(kDNSServiceFlagsAdd), 0, 0, nil, UInt16(kDNSServiceType_CNAME), 1, UInt16($0.count), $0.baseAddress, 0, context)
                }
                bytes.withUnsafeBytes {
                    callback?(reference, UInt32(kDNSServiceFlagsAdd), 0, 0, nil, 33, 1, UInt16($0.count), $0.baseAddress, 0, context)
                }
            }
        }
        return 0
    }
    func deallocate(reference: DNSServiceRef) {
        lock.lock(); defer { lock.unlock() }
        deallocations += 1
        callback = nil; context = nil
    }
    var counts: (queries: Int, deallocations: Int) {
        lock.lock(); defer { lock.unlock() }
        return (queries, deallocations)
    }
    var flags: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return queryFlags
    }
}

final class SieveServiceDiscoveryTests: XCTestCase {
    private func record(_ target: String, priority: UInt16 = 0, weight: UInt16 = 0, port: UInt16 = 4190) -> SieveSRVRecord {
        SieveSRVRecord(priority: priority, weight: weight, port: port, target: target)
    }
    private func discover(_ records: [SieveSRVRecord], draw: UInt64 = 0, email: String = "user@example.org") async throws -> SieveServiceEndpoint {
        try await SieveServiceDiscovery(resolver: RecordingSRVResolver(records), random: FixedSieveRandom(draw)).discover(emailAddress: email)
    }
    private func expectError(_ expected: SieveServiceDiscoveryError, records: [SieveSRVRecord], email: String = "u@example.org") async {
        do { _ = try await discover(records, email: email); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, expected) }
    }

    func testLastAtCanonicalSourceExactQueryAndIdentityOrder() async throws {
        let resolver = RecordingSRVResolver([record("MAIL.Target.NET.")])
        let endpoint = try await SieveServiceDiscovery(resolver: resolver, random: FixedSieveRandom(0)).discover(emailAddress: "local@part@EXAMPLE.ORG")
        let names = await resolver.names
        XCTAssertEqual(names, ["_sieve._tcp.example.org"])
        XCTAssertEqual(endpoint.host, "mail.target.net")
        XCTAssertEqual(endpoint.port, 4190)
        XCTAssertEqual(endpoint.referenceIdentifiers, [.srv(service: "sieve", domain: "example.org"), .dns("example.org")])
    }

    func testAutomaticDiscoveryValidatesCompleteSRVOwnerNameLength() async throws {
        let acceptedDomain = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                              String(repeating: "c", count: 63), String(repeating: "d", count: 49)].joined(separator: ".")
        let rejectedDomain = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                              String(repeating: "c", count: 63), String(repeating: "d", count: 50)].joined(separator: ".")
        XCTAssertEqual(acceptedDomain.utf8.count, 241)
        XCTAssertEqual(rejectedDomain.utf8.count, 242)

        let resolver = RecordingSRVResolver([record("mail.example.org")])
        _ = try await SieveServiceDiscovery(resolver: resolver, random: FixedSieveRandom(0))
            .discover(emailAddress: "user@\(acceptedDomain)")
        let acceptedQueries = await resolver.names
        XCTAssertEqual(acceptedQueries, ["_sieve._tcp.\(acceptedDomain)"])

        do {
            _ = try await SieveServiceDiscovery(resolver: resolver, random: FixedSieveRandom(0))
                .discover(emailAddress: "user@\(rejectedDomain)")
            XCTFail("Accepted an SRV owner name longer than 253 text bytes")
        } catch {
            XCTAssertEqual(error as? SieveServiceDiscoveryError, .invalidEmailAddress)
        }
        let finalQueries = await resolver.names
        XCTAssertEqual(finalQueries.count, 1)
    }

    func testInvalidEmailAndSourceDomainNeverQueryResolver() async {
        let resolver = RecordingSRVResolver([])
        let discovery = SieveServiceDiscovery(resolver: resolver, random: FixedSieveRandom(0))
        for email in ["", "user", "@example.org", "user@", "u@localhost", "u@EXAMPLE.ORG.", "u@a..org", "u@-a.org", "u@a-.org", "u@a_b.org", "u@é.org", "u@127.0.0.1", "u@[::1]", "u@::1", "u@ example.org", "u@" + String(repeating: "a", count: 64) + ".org", "u@" + Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: ".")] {
            do { _ = try await discovery.discover(emailAddress: email); XCTFail(email) }
            catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .invalidEmailAddress, email) }
        }
        let names = await resolver.names
        XCTAssertTrue(names.isEmpty)
    }

    func testLowestPriorityAndCanonicalOrderingBeforeUniformDraw() async throws {
        let records = [record("z.example.org", priority: 1), record("B.example.org.", priority: 0), record("a.example.org", priority: 0)]
        for answer in [records, records.reversed().map { $0 }] {
            let random = FixedSieveRandom(1)
            let endpoint = try await SieveServiceDiscovery(resolver: RecordingSRVResolver(answer), random: random).discover(emailAddress: "u@example.org")
            XCTAssertEqual(endpoint.host, "b.example.org")
            XCTAssertEqual(random.requestedBounds, [2])
        }
    }

    func testAllZeroWeightsUseEveryUniformIndexAndCanonicalDuplicatesRespectLimit() async throws {
        let records = [record("z.example.org"), record("a.example.org"), record("b.example.org")]
        for (draw, host) in ["a.example.org", "b.example.org", "z.example.org"].enumerated() {
            let random = FixedSieveRandom(UInt64(draw))
            let endpoint = try await SieveServiceDiscovery(resolver: RecordingSRVResolver(records), random: random).discover(emailAddress: "u@example.org")
            XCTAssertEqual(endpoint.host, host)
            XCTAssertEqual(random.requestedBounds, [3])
        }
        let stopped = expectation(description: "duplicate deallocated once")
        let result = try await resolver([reply(wire("MAIL.example.org"), more: true), reply(wire())], maximumRecords: 1, onCancel: { stopped.fulfill() }).records(for: "test")
        XCTAssertEqual(result, [record("mail.example.org")])
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testCanonicalPortThenWeightOrderingAndWeightedCumulativeBoundaries() async throws {
        let records = [record("same.example.org", weight: 3, port: 4191), record("same.example.org", weight: 2), record("same.example.org", weight: 0), record("z.example.org", weight: 5)]
        for (draw, host, port) in [(UInt64(0), "same.example.org", 4190), (1, "same.example.org", 4190), (2, "same.example.org", 4191), (4, "same.example.org", 4191), (5, "z.example.org", 4190), (9, "z.example.org", 4190)] {
            let random = FixedSieveRandom(draw)
            let endpoint = try await SieveServiceDiscovery(resolver: RecordingSRVResolver(records), random: random).discover(emailAddress: "u@example.org")
            XCTAssertEqual(endpoint.host, host); XCTAssertEqual(endpoint.port, port)
            XCTAssertEqual(random.requestedBounds, [10])
        }
    }

    func testCheckedWeightSumAndOutOfRangeDrawAreRejectedWithoutModulo() async {
        XCTAssertThrowsError(try SieveServiceDiscovery.checkedWeightTotal([UInt64.max, 1])) {
            XCTAssertEqual($0 as? SieveServiceDiscoveryError, .weightOverflow)
        }
        for weights: [UInt16] in [[0, 0], [2, 3]] {
            do {
                _ = try await discover(weights.enumerated().map { record("s\($0.offset).example.org", weight: $0.element) }, draw: UInt64.max)
                XCTFail("Unconstrained draw accepted")
            } catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .invalidRandomValue) }
        }
    }

    func testNoRecordsExplicitNoServiceAndInvalidRecordsFailClosed() async {
        await expectError(.noRecords, records: [])
        await expectError(.serviceUnavailable, records: [record(".")])
        for target in ["", "localhost", "bad..org", "-bad.org", "bad_.org", "é.org", "127.0.0.1", "[::1]", "a.org..", String(repeating: "a", count: 64) + ".org"] {
            await expectError(.invalidRecord, records: [record(target)])
        }
        await expectError(.invalidRecord, records: [record("valid.example.org", port: 0)])
        // Even invalid records at an unselected priority are rejected.
        await expectError(.invalidRecord, records: [record("valid.example.org"), record("bad..org", priority: 1)])
    }

    private func wire(_ target: String = "mail.example.org", priority: UInt16 = 0, weight: UInt16 = 0, port: UInt16 = 4190) -> [UInt8] {
        var bytes = [UInt8(priority >> 8), UInt8(priority & 255), UInt8(weight >> 8), UInt8(weight & 255), UInt8(port >> 8), UInt8(port & 255)]
        if target != "." {
            for label in target.split(separator: ".", omittingEmptySubsequences: false) {
                bytes.append(UInt8(label.utf8.count)); bytes += label.utf8
            }
        }
        bytes.append(0)
        return bytes
    }
    private func reply(_ bytes: [UInt8], add: Bool = true, more: Bool = false, error: Int32 = 0) -> DNSServiceReply {
        DNSServiceReply(add: add, moreComing: more, errorCode: error, recordType: 33, recordClass: 1, rdata: bytes)
    }
    private func resolver(_ script: [DNSServiceReply], timeout: TimeInterval = 1, maximumRecords: Int = 256, maximumBytes: Int = 65536, startError: SieveServiceDiscoveryError? = nil, onStart: (() -> Void)? = nil, onCancel: @escaping () -> Void) -> DNSServiceResolver {
        DNSServiceResolver(timeout: timeout, maximumRecords: maximumRecords, maximumRDataBytes: maximumBytes) {
            ScriptedDNSQuery(script, startError: startError, onStart: onStart, onCancel: onCancel)
        }
    }

    func testResolverFirstBatchDuplicateAddsAndMatchingOrAbsentRemovals() async throws {
        let stopped = expectation(description: "deallocated once"); stopped.assertForOverFulfill = true
        let a = wire("A.example.org"), b = wire("b.example.org")
        let result = try await resolver([
            reply(a, more: true), reply(wire("a.example.org"), more: true),
            reply(b, more: true), reply(wire("absent.example.org"), add: false, more: true),
            reply(a, add: false), reply(b, error: -1)
        ], onCancel: { stopped.fulfill() }).records(for: "_sieve._tcp.example.org")
        XCTAssertEqual(result, [record("b.example.org")])
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testResolverManualRDataParsingAndMalformedData() async {
        let badData: [[UInt8]] = [[], [0, 0, 0, 0, 16, 94], wire() + [0], Array(wire().dropLast()), [0, 0, 0, 0, 16, 94, 0xc0, 0x00], [0, 0, 0, 0, 16, 94, 64] + Array(repeating: 97, count: 64) + [0], wire("bad_.org"), wire("bad..org"), wire("é.org"), wire("127.0.0.1"), wire(port: 0)]
        for bytes in badData {
            let stopped = expectation(description: "malformed deallocated")
            do { _ = try await resolver([reply(bytes)], onCancel: { stopped.fulfill() }).records(for: "test"); XCTFail("Accepted \(bytes)") }
            catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .invalidRecord) }
            await fulfillment(of: [stopped], timeout: 1)
        }
        let stopped = expectation(description: "no service deallocated")
        do { _ = try await resolver([reply(wire("."))], onCancel: { stopped.fulfill() }).records(for: "test"); XCTFail() }
        catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .serviceUnavailable) }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testResolverBoundsCountAndCumulativeBytesIncludingDuplicateAndRemoval() async {
        let a = reply(wire(), more: true), b = reply(wire("b.example.org"))
        for (script, count, bytes) in [([a, b], 1, 65536), ([a, reply(wire())], 1, wire().count), ([a, reply(wire(), add: false)], 1, wire().count)] {
            let stopped = expectation(description: "bound deallocated")
            do { _ = try await resolver(script, maximumRecords: count, maximumBytes: bytes, onCancel: { stopped.fulfill() }).records(for: "test"); XCTFail() }
            catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .responseLimitExceeded) }
            await fulfillment(of: [stopped], timeout: 1)
        }
    }

    func testResolverTimeoutCancellationAndStartOrCallbackErrorCompleteOnce() async {
        let timedOut = expectation(description: "timeout deallocated")
        do { _ = try await resolver([], timeout: 0.01, onCancel: { timedOut.fulfill() }).records(for: "test"); XCTFail() }
        catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .timedOut) }
        await fulfillment(of: [timedOut], timeout: 1)

        let started = expectation(description: "query started"), cancelled = expectation(description: "cancel deallocated")
        let resolving = resolver([], onStart: { started.fulfill() }, onCancel: { cancelled.fulfill() })
        let task = Task { try await resolving.records(for: "test") }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 1)

        for startError in [false, true] {
            let stopped = expectation(description: "error deallocated once"); stopped.assertForOverFulfill = true
            do {
                _ = try await resolver([reply(wire(), error: -65537), reply(wire())], startError: startError ? .dnsService(-65537) : nil, onCancel: { stopped.fulfill() }).records(for: "test")
                XCTFail()
            } catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .dnsService(-65537)) }
            await fulfillment(of: [stopped], timeout: 1)
        }
    }

    func testSystemDNSServiceWrapperOwnsReferenceAndIgnoresUndefinedErrorArguments() async throws {
        for (queryError, dispatchError, callbackError) in [(Int32(0), Int32(0), Int32(0)), (-1, 0, 0), (0, -2, 0), (0, 0, -3)] {
            let client = StubDNSServiceClient(queryStatus: queryError, dispatchStatus: dispatchError, callbackError: callbackError)
            let resolver = DNSServiceResolver(timeout: 1, maximumRecords: 256, maximumRDataBytes: 65536) { SystemDNSServiceQuery(client: client) }
            do {
                let records = try await resolver.records(for: "_sieve._tcp.example.org")
                XCTAssertEqual(records, [record("mail.example.org", priority: 0x1234, weight: 0x5678)])
                XCTAssertEqual(queryError + dispatchError + callbackError, 0)
            } catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .dnsService(queryError + dispatchError + callbackError)) }
            XCTAssertEqual(client.counts.queries, 1)
            XCTAssertEqual(client.counts.deallocations, queryError == 0 ? 1 : 0)
        }
    }

    func testSystemDNSServiceWrapperRequestsAndMapsAuthoritativeNegativeAnswers() async throws {
        for error in [Int32(kDNSServiceErr_NoSuchName), Int32(kDNSServiceErr_NoSuchRecord)] {
            let client = StubDNSServiceClient(reply: .error(error))
            let resolver = DNSServiceResolver(timeout: 1, maximumRecords: 256, maximumRDataBytes: 65536) {
                SystemDNSServiceQuery(client: client)
            }
            let records = try await resolver.records(for: "_sieve._tcp.missing.example.org")
            XCTAssertEqual(records, [])
            XCTAssertNotEqual(client.flags & UInt32(kDNSServiceFlagsReturnIntermediates), 0)
            XCTAssertEqual(client.counts.deallocations, 1)
        }
    }

    func testSystemDNSServiceWrapperIgnoresCNAMEIntermediateUntilSRVAnswer() async throws {
        let client = StubDNSServiceClient(reply: .cnameThenSRV)
        let resolver = DNSServiceResolver(timeout: 1, maximumRecords: 256, maximumRDataBytes: 65536) {
            SystemDNSServiceQuery(client: client)
        }
        let records = try await resolver.records(for: "_sieve._tcp.alias.example.org")
        XCTAssertEqual(records, [record("mail.example.org", priority: 0x1234, weight: 0x5678)])
        XCTAssertEqual(client.counts.deallocations, 1)
    }

    func testSystemDNSServiceWrapperTimeoutAndCancellationDeallocateOnce() async {
        for cancel in [false, true] {
            let started = expectation(description: "system wrapper started")
            let client = StubDNSServiceClient(sendsReply: false, onStart: { started.fulfill() })
            let resolver = DNSServiceResolver(timeout: cancel ? 1 : 0.01, maximumRecords: 256, maximumRDataBytes: 65536) { SystemDNSServiceQuery(client: client) }
            let task = Task { try await resolver.records(for: "_sieve._tcp.example.org") }
            await fulfillment(of: [started], timeout: 1)
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail() }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? SieveServiceDiscoveryError, .timedOut) }
            }
            // Repeated cancellation after completion must not touch the released reference.
            task.cancel()
            XCTAssertEqual(client.counts.deallocations, 1)
        }
    }

    func testInvalidConfigurationAndUnexpectedRecordTypeOrClassFailClosed() async {
        for (timeout, count, bytes) in [(Double.nan, 1, 1), (.infinity, 1, 1), (Double.greatestFiniteMagnitude, 1, 1), (-1, 1, 1), (0, 1, 1), (1, 0, 1), (1, 1, 0)] {
            let mustNotStart = expectation(description: "invalid configuration cannot allocate"); mustNotStart.isInverted = true
            do { _ = try await resolver([], timeout: timeout, maximumRecords: count, maximumBytes: bytes, onStart: { mustNotStart.fulfill() }, onCancel: {}).records(for: "test"); XCTFail() }
            catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .invalidConfiguration) }
            await fulfillment(of: [mustNotStart], timeout: 0.001)
        }
        for (type, recordClass): (UInt16, UInt16) in [(1, 1), (33, 2)] {
            let stopped = expectation(description: "unexpected RR deallocated")
            let unexpected = DNSServiceReply(add: true, moreComing: false, errorCode: 0, recordType: type, recordClass: recordClass, rdata: wire())
            do { _ = try await resolver([unexpected], onCancel: { stopped.fulfill() }).records(for: "test"); XCTFail() }
            catch { XCTAssertEqual(error as? SieveServiceDiscoveryError, .invalidRecord) }
            await fulfillment(of: [stopped], timeout: 1)
        }
    }

    func testResolverPreCancelledTaskDoesNotStartAndEmptyBatchIsEmpty() async throws {
        let shouldNotStart = expectation(description: "must not start"); shouldNotStart.isInverted = true
        let resolving = resolver([], onStart: { shouldNotStart.fulfill() }, onCancel: {})
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await resolving.records(for: "test") }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [shouldNotStart], timeout: 0.02)
        let stopped = expectation(description: "empty batch deallocated")
        let result = try await resolver([reply(wire(), add: false)], onCancel: { stopped.fulfill() }).records(for: "test")
        XCTAssertTrue(result.isEmpty)
        await fulfillment(of: [stopped], timeout: 1)
    }
}
