import Foundation
import Security

internal protocol SecurityClient: Sendable {
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemSecurityClient: SecurityClient {
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
    func add(_ attributes: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(attributes, result)
    }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

public enum KeychainOperation: String, Equatable, Sendable { case read, update, add, delete }

public enum KeychainCredentialStoreError: Error, Equatable, Sendable {
    case operationFailed(KeychainOperation, OSStatus)
    case invalidData
}

public struct KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let service: String
    private let client: any SecurityClient

    public init(service: String = "com.sievepilot.credentials") {
        self.init(service: service, client: SystemSecurityClient())
    }

    internal init(service: String, client: any SecurityClient) {
        self.service = service
        self.client = client
    }

    public func read(accountID: AccountID) async throws -> Data? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = client.copyMatching(dictionary(query), result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainCredentialStoreError.operationFailed(.read, status) }
        guard let data = result as? Data else { throw KeychainCredentialStoreError.invalidData }
        return data
    }

    public func write(_ password: Data, accountID: AccountID) async throws {
        let mutablePassword = NSMutableData(data: password)
        defer { mutablePassword.resetBytes(in: NSRange(location: 0, length: mutablePassword.length)) }
        let query = dictionary(baseQuery(accountID: accountID))
        let updateAttributes = dictionary([kSecValueData: mutablePassword])
        let updateStatus = client.update(query, attributes: updateAttributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialStoreError.operationFailed(.update, updateStatus)
        }
        var add = baseQuery(accountID: accountID)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData] = mutablePassword
        let addStatus = client.add(dictionary(add), result: nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = client.update(query, attributes: updateAttributes)
            guard retryStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.operationFailed(.update, retryStatus)
            }
            return
        }
        throw KeychainCredentialStoreError.operationFailed(.add, addStatus)
    }

    public func delete(accountID: AccountID) async throws {
        let status = client.delete(dictionary(baseQuery(accountID: accountID)))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.operationFailed(.delete, status)
        }
    }

    private func baseQuery(accountID: AccountID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: accountID.sieveToken]
    }

    private func dictionary(_ values: [CFString: Any]) -> CFDictionary {
        values as CFDictionary
    }
}
