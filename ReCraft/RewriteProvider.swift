import Foundation

/// The one global choice of which remote API performs task rewrites.
/// Each provider has exactly one fixed model and request shape; there is no
/// per-task choice, model choice, retry or fallback to the other provider.
enum RewriteProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case openai

    /// Used when nothing is stored or the stored value is not recognized.
    static let defaultProvider = RewriteProvider.claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .openai:
            "OpenAI"
        }
    }

    /// The disclosure shown where a task prompt is edited: what is sent, and
    /// to whom, when the task is invoked.
    var taskPromptDisclosure: String {
        switch self {
        case .claude:
            "When this task is invoked, its complete prompt is sent unchanged to Claude as the system prompt and the exact selected text is sent as the only user message. ReCraft adds no other instructions. The API key remains in macOS Keychain."
        case .openai:
            "When this task is invoked, its complete prompt is sent unchanged to OpenAI as instructions and the exact selected text is sent as input. ReCraft adds no other instructions. The API key remains in macOS Keychain."
        }
    }
}

/// Persists the global provider choice in `UserDefaults`.
///
/// A missing or unrecognized stored value reads as `.claude` and is left
/// untouched; only an explicit `select(_:)` writes the key.
final class RewriteProviderSetting: @unchecked Sendable {
    static let defaultsKey = "rewriteProvider.v1"

    // UserDefaults is documented as thread-safe.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var current: RewriteProvider {
        guard let stored = defaults.string(forKey: Self.defaultsKey),
              let provider = RewriteProvider(rawValue: stored) else {
            return RewriteProvider.defaultProvider
        }
        return provider
    }

    func select(_ provider: RewriteProvider) {
        defaults.set(provider.rawValue, forKey: Self.defaultsKey)
    }
}
