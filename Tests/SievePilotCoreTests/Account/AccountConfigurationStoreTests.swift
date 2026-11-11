import Foundation
import XCTest
@testable import SievePilotCore

private actor MemoryConfigurationStore: AccountConfigurationStoring {
    var value: AccountConfiguration?
    var saveError: Error?
    var deleteError: Error?

    init(_ value: AccountConfiguration? = nil) { self.value = value }
    func load() async throws -> AccountConfiguration? { value }
    func save(_ configuration: AccountConfiguration) async throws {
        if let saveError { throw saveError }
        value = configuration
    }
    func delete() async throws {
        if let deleteError { throw deleteError }
        value = nil
    }
    func failSave(_ error: Error?) { saveError = error }
    func failDelete(_ error: Error?) { deleteError = error }
}

private actor MemoryCredentialStore: CredentialStoring {
    var values: [AccountID: Data] = [:]
    var writeFailures: [Int: Error] = [:]
    var writeCount = 0
    var deleteError: Error?

    func read(accountID: AccountID) async throws -> Data? { values[accountID] }
    func write(_ password: Data, accountID: AccountID) async throws {
        writeCount += 1
        if let error = writeFailures[writeCount] { throw error }
        values[accountID] = password
    }
    func delete(accountID: AccountID) async throws {
        if let deleteError { throw deleteError }
        values[accountID] = nil
    }
    func set(_ data: Data?, for accountID: AccountID) { values[accountID] = data }
    func failWrite(onCall call: Int, with error: Error?) { writeFailures[call] = error }
    func clearWriteFailures() { writeFailures = [:] }
    func failDelete(_ error: Error?) { deleteError = error }
}

final class AccountConfigurationStoreTests: XCTestCase {
    private let accountID = AccountID(rawValue: UUID(uuidString: "8CBCBCC8-2E3C-49BE-9464-A238AD398005")!)

    private func configuration(id: AccountID? = nil, username: String = "user", endpoint: AccountEndpointPolicy = .automatic(sourceDomain: "example.org")) throws -> AccountConfiguration {
        try AccountConfiguration(accountID: id ?? accountID, emailAddress: "user@example.org", username: username,
                                 endpointPolicy: endpoint, tlsPolicy: .startTLS)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SievePilot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAccountIDAndConfigurationUseExplicitStableSchemaWithoutSecrets() async throws {
        let encodedID = try JSONEncoder().encode(accountID)
        XCTAssertEqual(String(decoding: encodedID, as: UTF8.self), "\"8cbcbcc8-2e3c-49be-9464-a238ad398005\"")
        XCTAssertEqual(try JSONDecoder().decode(AccountID.self, from: encodedID), accountID)
        XCTAssertThrowsError(try JSONDecoder().decode(AccountID.self, from: Data("\"not-a-uuid\"".utf8)))

        let store = AccountConfigurationStore(baseDirectory: try temporaryDirectory())
        let configuration = try configuration(endpoint: .manual(host: "MAIL.EXAMPLE.ORG", port: 4190))
        try await store.save(configuration)
        let bytes = try Data(contentsOf: store.fileURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let account = try XCTUnwrap(object["account"] as? [String: Any])
        XCTAssertEqual(account["accountID"] as? String, accountID.sieveToken)
        XCTAssertEqual(account["tlsPolicy"] as? String, "startTLS")
        let endpoint = try XCTUnwrap(account["endpointPolicy"] as? [String: Any])
        XCTAssertEqual(endpoint["type"] as? String, "manual")
        XCTAssertEqual(endpoint["host"] as? String, "mail.example.org")
        XCTAssertEqual(endpoint["port"] as? Int, 4190)
        XCTAssertNil(account["password"])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret"))
        let loadedConfiguration = try await store.load()
        XCTAssertEqual(loadedConfiguration, configuration)
    }

    func testConfigurationValidationRejectsUnsafeInputsAndCanonicalizesStableFields() throws {
        for email in ["", "user", "@example.org", "user@", "user@localhost", "user@é.org"] {
            XCTAssertThrowsError(try AccountConfiguration(accountID: accountID, emailAddress: email, username: "user",
                                                           endpointPolicy: .automatic(sourceDomain: "example.org"), tlsPolicy: .startTLS))
        }
        for username in ["", "   ", "bad\u{0}name", "bad\nname"] {
            XCTAssertThrowsError(try AccountConfiguration(accountID: accountID, emailAddress: "user@example.org", username: username,
                                                           endpointPolicy: .automatic(sourceDomain: "example.org"), tlsPolicy: .startTLS))
        }
        for endpoint in [AccountEndpointPolicy.automatic(sourceDomain: "localhost"), .automatic(sourceDomain: "other.org"),
                         .manual(host: "localhost", port: 4190), .manual(host: "bad_.org", port: 4190),
                         .manual(host: "mail.example.org", port: 0), .manual(host: "mail.example.org", port: 65_536)] {
            XCTAssertThrowsError(try configuration(endpoint: endpoint), "\(endpoint)")
        }
        let valid = try AccountConfiguration(accountID: accountID, emailAddress: "User@EXAMPLE.ORG", username: " user ",
                                             endpointPolicy: .manual(host: "MAIL.EXAMPLE.ORG.", port: 4190), tlsPolicy: .startTLS)
        XCTAssertEqual(valid.emailAddress, "User@example.org")
        XCTAssertEqual(valid.username, "user")
        XCTAssertEqual(valid.endpointPolicy, .manual(host: "mail.example.org", port: 4190))
    }

    func testStoreUsesPrivatePermissionsAndFailsClosedForCorruptionOrUnknownVersion() async throws {
        let base = try temporaryDirectory()
        let store = AccountConfigurationStore(baseDirectory: base)
        let value = try configuration()
        try await store.save(value)
        let loadedValue = try await store.load()
        XCTAssertEqual(loadedValue, value)
        let directoryMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: store.directoryURL.path)[.posixPermissions] as? NSNumber)?.intValue)
        let fileMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)

        try Data("not json".utf8).write(to: store.fileURL)
        do { _ = try await store.load(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountConfigurationStoreError, .corruptSettings) }
        try Data("{\"version\":2,\"account\":{}}".utf8).write(to: store.fileURL)
        do { _ = try await store.load(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountConfigurationStoreError, .unsupportedVersion(2)) }
    }

    func testAtomicReplacementFailurePreservesPreviousBytes() async throws {
        let base = try temporaryDirectory()
        let initialStore = AccountConfigurationStore(baseDirectory: base)
        try await initialStore.save(try configuration(username: "before"))
        let previous = try Data(contentsOf: initialStore.fileURL)
        let failingStore = AccountConfigurationStore(baseDirectory: base) { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }
        do { try await failingStore.save(try configuration(username: "after")); XCTFail() }
        catch { }
        XCTAssertEqual(try Data(contentsOf: initialStore.fileURL), previous)
        let loadedUsername = try await initialStore.load()?.username
        XCTAssertEqual(loadedUsername, "before")
    }

    func testCoordinatorRollsBackCredentialWhenSettingsSaveFails() async throws {
        let old = try configuration(username: "old")
        let settings = MemoryConfigurationStore(old)
        let credentials = MemoryCredentialStore()
        await credentials.set(Data("old-password".utf8), for: accountID)
        await settings.failSave(CocoaError(.fileWriteUnknown))
        let coordinator = AccountPersistenceCoordinator(configurationStore: settings, credentialStore: credentials)

        do { try await coordinator.save(configuration: try configuration(username: "new"), password: Data("new-password".utf8)); XCTFail() }
        catch { XCTAssertEqual(error as? AccountPersistenceError, .settingsSaveFailed) }
        let restoredSettings = try await settings.load()
        let restoredPassword = try await credentials.read(accountID: accountID)
        XCTAssertEqual(restoredSettings, old)
        XCTAssertEqual(restoredPassword, Data("old-password".utf8))

        let newID = AccountID(rawValue: UUID())
        do { try await coordinator.save(configuration: try configuration(id: newID), password: Data("new".utf8)); XCTFail() }
        catch { XCTAssertEqual(error as? AccountPersistenceError, .settingsSaveFailed) }
        let removedNewPassword = try await credentials.read(accountID: newID)
        XCTAssertNil(removedNewPassword)
    }

    func testCoordinatorReportsRollbackFailureAndDeletesSettingsFirst() async throws {
        let settings = MemoryConfigurationStore(try configuration())
        let credentials = MemoryCredentialStore()
        await credentials.set(Data("old".utf8), for: accountID)
        await settings.failSave(CocoaError(.fileWriteUnknown))
        await credentials.failWrite(onCall: 2, with: CocoaError(.fileWriteNoPermission))
        let coordinator = AccountPersistenceCoordinator(configurationStore: settings, credentialStore: credentials)
        do { try await coordinator.save(configuration: try configuration(username: "new"), password: Data("new".utf8)); XCTFail() }
        catch { XCTAssertEqual(error as? AccountPersistenceError, .inconsistentState) }

        await settings.failSave(nil)
        await credentials.clearWriteFailures()
        await credentials.failDelete(CocoaError(.fileWriteNoPermission))
        do { try await coordinator.delete(accountID: accountID); XCTFail() }
        catch { XCTAssertEqual(error as? AccountPersistenceError, .credentialDeleteFailed) }
        let deletedSettings = try await settings.load()
        let retainedPassword = try await credentials.read(accountID: accountID)
        XCTAssertNil(deletedSettings)
        XCTAssertEqual(retainedPassword, Data("new".utf8))
    }
}
