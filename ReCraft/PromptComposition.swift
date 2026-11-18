import Foundation

enum RewritePromptPolicy {
    static func acceptedOutput(_ output: String) -> String? {
        guard output.contains(where: { !$0.isWhitespace }) else {
            return nil
        }
        return output
    }

    static func selectionIsUnchanged(
        original: String,
        current: String
    ) -> Bool {
        ExactText.matches(original, current)
    }
}
