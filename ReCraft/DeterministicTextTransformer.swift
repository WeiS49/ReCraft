import Foundation

enum DeterministicTextTransformer {
    static let prefix = "[ReCraft] "

    static func transform(_ selectedText: String) -> String {
        prefix + selectedText
    }
}
