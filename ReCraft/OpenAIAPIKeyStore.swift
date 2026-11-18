import Foundation
import LocalAuthentication
import Security

enum APIKeyStoreError: Error, Equatable {
    case emptyKey
    case invalidData
    case unhandledStatus(OSStatus)
}

protocol APIKeyStoring: Sendable {
    func containsKey() async throws -> Bool
    func loadKey() async throws -> String?
    func saveKey(_ key: String) async throws
    func deleteKey() async throws
}

actor OpenAIAPIKeyStore: APIKeyStoring {
    static let service = "com.weis49.ReCraft.openai-api-key"
    static let account = "default"

    func containsKey() throws -> Bool {
        var query = noninteractiveReadQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnAttributes] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw APIKeyStoreError.unhandledStatus(status)
        }
    }

    func loadKey() throws -> String? {
        var query = noninteractiveReadQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw APIKeyStoreError.invalidData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.unhandledStatus(status)
        }
    }

    func saveKey(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw APIKeyStoreError.emptyKey
        }

        let value = Data(normalized.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData: value] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item[kSecValueData] = value
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw APIKeyStoreError.unhandledStatus(addStatus)
            }
        default:
            throw APIKeyStoreError.unhandledStatus(updateStatus)
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.unhandledStatus(status)
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
        ]
    }

    private var noninteractiveReadQuery: [CFString: Any] {
        var query = baseQuery
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
        return query
    }
}
