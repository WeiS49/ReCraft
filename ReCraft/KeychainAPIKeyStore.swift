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

/// One Keychain generic-password item per provider. Both providers share this
/// implementation, including the non-interactive read context; only the
/// service name differs. The OpenAI service and the account must not change:
/// they identify the key already stored by installed copies.
actor KeychainAPIKeyStore: APIKeyStoring {
    static let openAIService = "com.weis49.ReCraft.openai-api-key"
    static let anthropicService = "com.weis49.ReCraft.anthropic-api-key"
    static let account = "default"

    static func service(for provider: RewriteProvider) -> String {
        switch provider {
        case .claude:
            anthropicService
        case .openai:
            openAIService
        }
    }

    nonisolated let service: String

    init(service: String) {
        self.service = service
    }

    init(provider: RewriteProvider) {
        self.init(service: Self.service(for: provider))
    }

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
            kSecAttrService: service,
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
