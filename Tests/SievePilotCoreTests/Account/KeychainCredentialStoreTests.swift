import Foundation
import Security
import XCTest
@testable import SievePilotCore

private final class StubSecurityClient: SecurityClient, @unchecked Sendable {
    private let lock = NSLock()
    var item: Data?
    var forcedCopyStatus: OSStatus?
    var updateStatuses: [OSStatus] = []
    var addStatuses: [OSStatus] = []
    var deleteStatuses: [OSStatus] = []
    private(set) var copyQueries: [NSDictionary] = []
    private(set) var updateQueries: [NSDictionary] = []
    private(set) var updateAttributes: [NSDictionary] = []
    private(set) var addAttributes: [NSDictionary] = []
    private(set) var deleteQueries: [NSDictionary] = []
    private(set) var passwordBuffers: [NSMutableData] = []

    private func object(_ dictionary: CFDictionary) -> NSDictionary { dictionary as NSDictionary }
    private func password(in dictionary: NSDictionary) -> NSMutableData? {
        dictionary[kSecValueData] as? NSMutableData
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        copyQueries.append(object(query))
        if let forcedCopyStatus { return forcedCopyStatus }
        guard let item else { return errSecItemNotFound }
        result?.pointee = item as CFData
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let queryObject = object(query), attributesObject = object(attributes)
        updateQueries.append(queryObject); updateAttributes.append(attributesObject)
        if let buffer = password(in: attributesObject) { passwordBuffers.append(buffer) }
        let status = updateStatuses.isEmpty ? (item == nil ? errSecItemNotFound : errSecSuccess) : updateStatuses.removeFirst()
        if status == errSecSuccess, let buffer = password(in: attributesObject) { item = Data(referencing: buffer) }
        return status
    }

    func add(_ attributes: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let object = object(attributes)
        addAttributes.append(object)
        if let buffer = password(in: object) { passwordBuffers.append(buffer) }
        let status = addStatuses.isEmpty ? (item == nil ? errSecSuccess : errSecDuplicateItem) : addStatuses.removeFirst()
        if status == errSecSuccess, let buffer = password(in: object) { item = Data(referencing: buffer) }
        return status
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        deleteQueries.append(object(query))
        let status = deleteStatuses.isEmpty ? (item == nil ? errSecItemNotFound : errSecSuccess) : deleteStatuses.removeFirst()
        if status == errSecSuccess { item = nil }
        return status
    }
}

final class KeychainCredentialStoreTests: XCTestCase {
    private let accountID = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)
    private let service = "com.example.SievePilot.tests"

    private func assertBaseQuery(_ query: NSDictionary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService] as? String, service, file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount] as? String, accountID.sieveToken, file: file, line: line)
    }

    func testReadUsesGenericPasswordQueryAndHandlesNotFound() async throws {
        let client = StubSecurityClient()
        let store = KeychainCredentialStore(service: service, client: client)
        let missing = try await store.read(accountID: accountID)
        XCTAssertNil(missing)
        client.item = Data("synthetic-password".utf8)
        let loaded = try await store.read(accountID: accountID)
        XCTAssertEqual(loaded, Data("synthetic-password".utf8))
        XCTAssertEqual(client.copyQueries.count, 2)
        assertBaseQuery(client.copyQueries[1])
        XCTAssertEqual(client.copyQueries[1][kSecReturnData] as? Bool, true)
        XCTAssertEqual(client.copyQueries[1][kSecMatchLimit] as? String, kSecMatchLimitOne as String)
    }

    func testWriteUpdatesThenAddsAndRetriesDuplicateRace() async throws {
        let client = StubSecurityClient()
        let store = KeychainCredentialStore(service: service, client: client)

        client.item = Data("old".utf8)
        try await store.write(Data("updated".utf8), accountID: accountID)
        XCTAssertEqual(client.item, Data("updated".utf8))
        XCTAssertEqual(client.updateQueries.count, 1)
        assertBaseQuery(client.updateQueries[0])

        client.item = nil
        try await store.write(Data("added".utf8), accountID: accountID)
        XCTAssertEqual(client.item, Data("added".utf8))
        let add = try XCTUnwrap(client.addAttributes.last)
        assertBaseQuery(add)
        XCTAssertEqual(add[kSecAttrAccessible] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        client.item = nil
        client.updateStatuses = [errSecItemNotFound, errSecSuccess]
        client.addStatuses = [errSecDuplicateItem]
        try await store.write(Data("race".utf8), accountID: accountID)
        XCTAssertEqual(client.updateQueries.count, 4)
        XCTAssertEqual(client.addAttributes.count, 2)
    }

    func testTemporaryPasswordBuffersAreWipedAndErrorsAreRedacted() async {
        let client = StubSecurityClient()
        client.updateStatuses = [errSecAuthFailed]
        let store = KeychainCredentialStore(service: service, client: client)
        let secret = Data("synthetic-super-secret".utf8)
        do { try await store.write(secret, accountID: accountID); XCTFail() }
        catch {
            XCTAssertEqual(error as? KeychainCredentialStoreError, .operationFailed(.update, errSecAuthFailed))
            XCTAssertFalse(String(describing: error).contains("synthetic-super-secret"))
        }
        XCTAssertFalse(client.passwordBuffers.isEmpty)
        for buffer in client.passwordBuffers {
            XCTAssertEqual(Data(referencing: buffer), Data(repeating: 0, count: secret.count))
        }

        client.forcedCopyStatus = errSecInteractionNotAllowed
        do { _ = try await store.read(accountID: accountID); XCTFail() }
        catch { XCTAssertEqual(error as? KeychainCredentialStoreError, .operationFailed(.read, errSecInteractionNotAllowed)) }
    }

    func testDeleteUsesStableIdentityAndTreatsMissingAsSuccess() async throws {
        let client = StubSecurityClient()
        let store = KeychainCredentialStore(service: service, client: client)
        try await store.delete(accountID: accountID)
        client.item = Data("value".utf8)
        try await store.delete(accountID: accountID)
        XCTAssertEqual(client.deleteQueries.count, 2)
        assertBaseQuery(client.deleteQueries[1])
        XCTAssertNil(client.item)
    }

    func testOptInKeychainIntegrationUsesSyntheticRandomServiceAndCleansUp() async throws {
        guard ProcessInfo.processInfo.environment["SIEVEPILOT_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set SIEVEPILOT_KEYCHAIN_INTEGRATION=1 to run")
        }
        let service = "com.sievepilot.integration.\(UUID().uuidString)"
        let id = AccountID(rawValue: UUID())
        let store = KeychainCredentialStore(service: service)
        let synthetic = Data("synthetic-\(UUID().uuidString)".utf8)
        do {
            try await store.write(synthetic, accountID: id)
            let loaded = try await store.read(accountID: id)
            XCTAssertEqual(loaded, synthetic)
            try await store.delete(accountID: id)
            let deleted = try await store.read(accountID: id)
            XCTAssertNil(deleted)
        } catch {
            try? await store.delete(accountID: id)
            throw error
        }
    }
}
