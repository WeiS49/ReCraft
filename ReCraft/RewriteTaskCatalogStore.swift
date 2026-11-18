import Foundation

enum RewriteTaskCatalogStoredValue: Equatable {
    case missing
    case data(Data)
    case invalidType
}

@MainActor
protocol RewriteTaskCatalogDataStoring: AnyObject {
    func storedValue() throws -> RewriteTaskCatalogStoredValue
    func replaceData(_ data: Data) throws
}

enum UserDefaultsRewriteTaskCatalogStoreError: Error, Equatable {
    case writeDidNotPersist
}

@MainActor
final class UserDefaultsRewriteTaskCatalogStore: RewriteTaskCatalogDataStoring {
    static let preferenceKey = "rewriteTaskCatalog.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func storedValue() -> RewriteTaskCatalogStoredValue {
        guard let storedObject = defaults.object(forKey: Self.preferenceKey) else {
            return .missing
        }
        guard let data = storedObject as? Data else {
            return .invalidType
        }
        return .data(data)
    }

    func replaceData(_ data: Data) throws {
        let previousValue = defaults.object(forKey: Self.preferenceKey)
        defaults.set(data, forKey: Self.preferenceKey)

        guard defaults.data(forKey: Self.preferenceKey) == data else {
            restore(previousValue)
            throw UserDefaultsRewriteTaskCatalogStoreError.writeDidNotPersist
        }
    }

    private func restore(_ value: Any?) {
        if let value {
            defaults.set(value, forKey: Self.preferenceKey)
        } else {
            defaults.removeObject(forKey: Self.preferenceKey)
        }
    }
}

@MainActor
final class RewriteTaskCatalogPersistence {
    struct PreparedSave: Equatable {
        let catalog: RewriteTaskCatalog
        fileprivate let data: Data
    }

    enum RecoveryReason: Equatable {
        case invalidStoredType
        case corruptData
        case unsupportedSchemaVersion(Int)
        case invalidCatalog([RewriteTaskCatalogValidationIssue])
        case storageUnavailable
    }

    enum LoadState: Equatable {
        case ready(catalog: RewriteTaskCatalog, initialized: Bool)
        case recovery(reason: RecoveryReason)
    }

    enum SaveError: Error, Equatable {
        case invalidCatalog([RewriteTaskCatalogValidationIssue])
        case encodingFailed
        case storageFailed
    }

    private let store: any RewriteTaskCatalogDataStoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        store: any RewriteTaskCatalogDataStoring,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.store = store
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() -> LoadState {
        let storedValue: RewriteTaskCatalogStoredValue
        do {
            storedValue = try store.storedValue()
        } catch {
            return .recovery(reason: .storageUnavailable)
        }

        switch storedValue {
        case .missing:
            do {
                try store.replaceData(try encoded(RewriteTaskCatalog.initial))
                return .ready(catalog: .initial, initialized: true)
            } catch {
                return .recovery(reason: .storageUnavailable)
            }

        case .invalidType:
            return .recovery(reason: .invalidStoredType)

        case let .data(data):
            let catalog: RewriteTaskCatalog
            do {
                catalog = try decoder.decode(RewriteTaskCatalog.self, from: data)
            } catch {
                return .recovery(reason: .corruptData)
            }

            let issues = RewriteTaskCatalogValidator.issues(in: catalog)
            if case let .unsupportedSchemaVersion(version)? = issues.first {
                return .recovery(reason: .unsupportedSchemaVersion(version))
            }
            guard issues.isEmpty else {
                return .recovery(reason: .invalidCatalog(issues))
            }
            return .ready(catalog: catalog, initialized: false)
        }
    }

    func save(_ catalog: RewriteTaskCatalog) throws {
        try commit(prepareSave(catalog))
    }

    func prepareSave(_ catalog: RewriteTaskCatalog) throws -> PreparedSave {
        let issues = RewriteTaskCatalogValidator.issues(in: catalog)
        guard issues.isEmpty else {
            throw SaveError.invalidCatalog(issues)
        }

        let data: Data
        do {
            data = try encoded(catalog)
        } catch {
            throw SaveError.encodingFailed
        }

        return PreparedSave(catalog: catalog, data: data)
    }

    func commit(_ preparedSave: PreparedSave) throws {
        do {
            try store.replaceData(preparedSave.data)
        } catch {
            throw SaveError.storageFailed
        }
    }

    func prepareResetAfterUserConfirmation() throws -> PreparedSave {
        try prepareSave(.initial)
    }

    private func encoded(_ catalog: RewriteTaskCatalog) throws -> Data {
        try encoder.encode(catalog)
    }
}
