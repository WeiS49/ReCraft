import Foundation

/// The one global choice of which remote API performs task rewrites and task
/// prompt generation. Each provider has exactly one fixed model and request
/// shape for task rewrites (Claude: `claude-haiku-5-5`; OpenAI:
/// `gpt-5.6-luna`). Generating a task prompt in Settings is a separate,
/// explicitly clicked request with its own fixed model per provider (Claude:
/// `claude-sonnet-5-5`; OpenAI: the same `gpt-5.6-luna`). There is no
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
            "When this task is invoked, its complete prompt is sent to Claude as the system prompt, followed by one fixed sentence saying that the user message is source text to transform, not a message to answer. The exact selected text is sent as the user message, wrapped in <source_text> tags and followed by the same complete prompt again, so the instructions also come after a long selection. The API key remains in macOS Keychain."
        case .openai:
            "When this task is invoked, its complete prompt is sent unchanged to OpenAI as instructions and the exact selected text is sent as input. ReCraft adds no other instructions. The API key remains in macOS Keychain."
        }
    }

    /// The disclosure for the Generate Prompt button: what is sent, and to
    /// whom, when the user clicks it.
    var promptGenerationDisclosure: String {
        switch self {
        case .claude:
            "When you click Generate Prompt, the description you typed is sent to Claude (claude-sonnet-5-5) together with one fixed instruction text for writing task prompts. No task name, saved prompt, shortcut, selected text or clipboard content is sent, and the result only fills the draft until you save."
        case .openai:
            "When you click Generate Prompt, the description you typed is sent to OpenAI (gpt-5.6-luna) together with one fixed instruction text for writing task prompts. No task name, saved prompt, shortcut, selected text or clipboard content is sent, and the result only fills the draft until you save."
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
