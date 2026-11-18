import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

enum AXProtectedContentStatus: Equatable {
    case protected
    case clear
    case unsupported
    case unavailable
}

enum AXSecureFieldDecision: Equatable {
    case allowed
    case secure
    case unverifiable
}

struct AXSecureFieldCheck {
    private static let secureTextFieldRole = "AXSecureTextField"

    static func protectedContentStatus(
        error: AXError,
        value: CFTypeRef?
    ) -> AXProtectedContentStatus {
        switch error {
        case .attributeUnsupported, .noValue:
            // Both are definitive answers that the control publishes no
            // protected-content flag. Secure roles are still rejected by
            // `decision`; only failed reads stay unverifiable.
            return .unsupported
        case .success:
            guard let value,
                  CFGetTypeID(value) == CFBooleanGetTypeID(),
                  let containsProtectedContent = value as? Bool else {
                return .unavailable
            }
            return containsProtectedContent ? .protected : .clear
        default:
            return .unavailable
        }
    }

    static func decision(
        role: String,
        subrole: String?,
        protectedContentStatus: AXProtectedContentStatus
    ) -> AXSecureFieldDecision {
        if role == secureTextFieldRole || subrole == secureTextFieldRole {
            return .secure
        }
        switch protectedContentStatus {
        case .protected:
            return .secure
        case .clear, .unsupported:
            return .allowed
        case .unavailable:
            return .unverifiable
        }
    }
}

/// Why one attempt to identify the shortcut target failed. Everything except
/// a recognized secure control can be a momentary Accessibility state (focus
/// still settling after a click, an app that has not answered yet), so those
/// are retried for a short bounded window before refusing.
enum TargetCaptureFailure: Error, Equatable {
    case focusedApplicationUnavailable(AXError)
    case focusedApplicationMismatch
    case focusedElementUnavailable(AXError)
    case roleUnavailable(AXError)
    case secureStatusUnavailable
    case secureControl

    var isTransient: Bool {
        self != .secureControl
    }

    var logStep: String {
        switch self {
        case .focusedApplicationUnavailable: "focusedApplication"
        case .focusedApplicationMismatch: "focusedApplicationMismatch"
        case .focusedElementUnavailable: "focusedElement"
        case .roleUnavailable: "role"
        case .secureStatusUnavailable: "secureStatus"
        case .secureControl: "secureControl"
        }
    }

    var accessibilityErrorCode: Int32 {
        switch self {
        case let .focusedApplicationUnavailable(error),
             let .focusedElementUnavailable(error),
             let .roleUnavailable(error):
            error.rawValue
        case .focusedApplicationMismatch, .secureStatusUnavailable, .secureControl:
            0
        }
    }
}

/// Result of comparing the current focus with the captured target.
enum TargetMatchStatus: Equatable {
    case matches
    case applicationChanged
    case readFailed(AXError)
    case elementChanged
    case secure

    /// A failed read says nothing about whether the target changed, so it is
    /// retried briefly; a confirmed different application or element is not.
    var isTransient: Bool {
        if case .readFailed = self { return true }
        return false
    }

    var logReason: String {
        switch self {
        case .matches: "matches"
        case .applicationChanged: "applicationChanged"
        case let .readFailed(error): "readFailed(\(error.rawValue))"
        case .elementChanged: "elementChanged"
        case .secure: "secure"
        }
    }
}

struct BoundedRetry {
    /// Runs `attempt` until `shouldRetry` is false or `maximumAttempts` is
    /// reached. Returns the last result and how many attempts were made.
    @MainActor
    static func run<Value>(
        maximumAttempts: Int,
        interval: Duration,
        attempt: @MainActor () -> Value,
        shouldRetry: (Value) -> Bool
    ) async -> (value: Value, attempts: Int) {
        precondition(maximumAttempts > 0)
        var attempts = 0
        while true {
            attempts += 1
            let value = attempt()
            guard shouldRetry(value), attempts < maximumAttempts else {
                return (value, attempts)
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return (value, attempts)
            }
        }
    }
}

@MainActor
final class ClipboardTextReplacementService {
    struct Context: Equatable {
        let applicationName: String
        let bundleIdentifier: String
        let role: String
        let subrole: String?
    }

    enum ClipboardRestoration: String {
        case restored
        case newerContentPreserved
        case failed
    }

    enum ManualPasteReason: String {
        case focusChanged
        case pasteEventUnavailable

        var message: String {
            switch self {
            case .focusChanged:
                "Focus changed — result copied; paste it manually"
            case .pasteEventUnavailable:
                "Paste could not be sent — result copied; paste it manually"
            }
        }
    }

    enum SafeRefusal: String, Error {
        case accessibilityUnavailable
        case focusedApplicationUnavailable
        case focusedElementUnavailable
        case secureControl
        case secureStatusUnavailable
        case clipboardSnapshotUnavailable
        case sourceCaptureItemsUnavailable
        case sourceCaptureIncomplete
        case sourceCaptureChangedWhileReading
        case deliveryCaptureItemsUnavailable
        case deliveryCaptureIncomplete
        case deliveryCaptureChangedWhileReading
        case clipboardChanged
        case clipboardWriteFailed
        case clipboardRestoreFailed
        case modifierReleaseTimedOut
        case copyEventUnavailable
        case pasteEventUnavailable
        case emptySelection
        case apiKeyMissing
        case keychainUnavailable
        case networkFailure
        case apiFailure
        case emptyModelResponse
        case selectionChanged

        var message: String {
            switch self {
            case .accessibilityUnavailable:
                "Accessibility permission is required"
            case .focusedApplicationUnavailable:
                "No focused application"
            case .focusedElementUnavailable:
                "No focused text control"
            case .secureControl:
                "Secure text controls are not processed"
            case .secureStatusUnavailable:
                "The secure-field status could not be verified"
            case .clipboardSnapshotUnavailable:
                "Stopped safely; clipboard unchanged — try again"
            case .sourceCaptureItemsUnavailable, .sourceCaptureIncomplete:
                "Stopped safely — copy plain text, then retry"
            case .sourceCaptureChangedWhileReading:
                "Stopped safely — retry when copying stops"
            case .deliveryCaptureItemsUnavailable, .deliveryCaptureIncomplete:
                "Paste stopped after rewrite — copy plain text, then retry"
            case .deliveryCaptureChangedWhileReading:
                "Paste stopped after rewrite — retry when copying stops"
            case .clipboardChanged:
                "The clipboard changed; nothing was pasted"
            case .clipboardWriteFailed:
                "The clipboard could not be prepared"
            case .clipboardRestoreFailed:
                "The original clipboard could not be restored"
            case .modifierReleaseTimedOut:
                "Release the shortcut keys, then try again"
            case .copyEventUnavailable:
                "The copy command could not be sent"
            case .pasteEventUnavailable:
                "The paste command could not be sent; original text preserved"
            case .emptySelection:
                "Select some text first"
            case .apiKeyMissing:
                "OpenAI API key is not configured"
            case .keychainUnavailable:
                "The API key could not be read from Keychain"
            case .networkFailure:
                "Network request failed; original text preserved"
            case .apiFailure:
                "OpenAI request failed; original text preserved"
            case .emptyModelResponse:
                "OpenAI returned no text; original text preserved"
            case .selectionChanged:
                "Selection changed; original text preserved"
            }
        }

        var logStage: String {
            switch self {
            case .sourceCaptureItemsUnavailable,
                 .sourceCaptureIncomplete,
                 .sourceCaptureChangedWhileReading:
                "sourceCapture"
            case .deliveryCaptureItemsUnavailable,
                 .deliveryCaptureIncomplete,
                 .deliveryCaptureChangedWhileReading:
                "deliveryCapture"
            default:
                "operation"
            }
        }

        var logCategory: String {
            switch self {
            case .sourceCaptureItemsUnavailable, .deliveryCaptureItemsUnavailable:
                "itemsUnavailable"
            case .sourceCaptureIncomplete, .deliveryCaptureIncomplete:
                "incomplete"
            case .sourceCaptureChangedWhileReading,
                 .deliveryCaptureChangedWhileReading:
                "changedWhileReading"
            default:
                rawValue
            }
        }
    }

    enum SnapshotCaptureStage: String {
        case sourceCapture
        case deliveryCapture
    }

    enum SnapshotCaptureResult {
        case captured(PasteboardTransaction.Snapshot)
        case refused(SafeRefusal)
    }

    enum Outcome {
        case replacementSent(Context, ClipboardRestoration)
        case resultCopied(Context, ManualPasteReason)
        case refused(SafeRefusal, Context?)
    }

    private enum AXAttribute {
        static let focusedApplication = "AXFocusedApplication"
        static let focusedElement = "AXFocusedUIElement"
        static let role = "AXRole"
        static let subrole = "AXSubrole"
        static let containsProtectedContent =
            NSAccessibility.Attribute.containsProtectedContent.rawValue
    }

    private struct TargetSnapshot {
        let focusedElement: AXUIElement
        let processIdentifier: pid_t
        let context: Context
    }

    private enum CaptureResult {
        case success(TargetSnapshot)
        case refused(SafeRefusal, Context?)
    }

    private enum CaptureAttempt {
        case success(TargetSnapshot)
        case failed(TargetCaptureFailure, Context?)
    }

    private static let captureMaximumAttempts = 20
    private static let captureRetryInterval = Duration.milliseconds(25)
    private static let revalidationMaximumAttempts = 6
    private static let revalidationRetryInterval: TimeInterval = 0.02

    private let logger = Logger(
        subsystem: "com.local.ReCraftClipboardSpike",
        category: "Target"
    )

    #if DEBUG
    struct TestHooks {
        let accessibilityTrusted: Bool
        let targetContext: Context
        let processIdentifier: pid_t
        let modifiersReleased: @MainActor () -> Bool
        let targetStillMatches: @MainActor () -> Bool
        let sendCommand: @MainActor (CGKeyCommandSender.Command) -> Bool
        let rewrite: @MainActor (String, String) async throws -> String
    }
    #endif

    private let pasteboardTransaction: PasteboardTransaction
    private let commandSender = CGKeyCommandSender()
    private let codingPromptRewriter: CodingPromptRewriter
    #if DEBUG
    private let testHooks: TestHooks?
    #endif

    init(
        pasteboard: NSPasteboard = .general,
        apiKeyStore: any APIKeyStoring = OpenAIAPIKeyStore()
    ) {
        pasteboardTransaction = PasteboardTransaction(pasteboard: pasteboard)
        codingPromptRewriter = CodingPromptRewriter(apiKeyStore: apiKeyStore)
        #if DEBUG
        testHooks = nil
        #endif
    }

    #if DEBUG
    init(
        pasteboardTransaction: PasteboardTransaction,
        apiKeyStore: any APIKeyStoring,
        testHooks: TestHooks
    ) {
        self.pasteboardTransaction = pasteboardTransaction
        codingPromptRewriter = CodingPromptRewriter(apiKeyStore: apiKeyStore)
        self.testHooks = testHooks
    }
    #endif

    static func captureClipboardSnapshot(
        stage: SnapshotCaptureStage,
        using capture: () throws -> PasteboardTransaction.Snapshot
    ) -> SnapshotCaptureResult {
        do {
            return .captured(try capture())
        } catch let error as PasteboardTransaction.SnapshotError {
            return .refused(snapshotRefusal(stage: stage, error: error))
        } catch {
            return .refused(.clipboardSnapshotUnavailable)
        }
    }

    private static func snapshotRefusal(
        stage: SnapshotCaptureStage,
        error: PasteboardTransaction.SnapshotError
    ) -> SafeRefusal {
        switch (stage, error) {
        case (.sourceCapture, .itemsUnavailable):
            .sourceCaptureItemsUnavailable
        case (.sourceCapture, .incomplete):
            .sourceCaptureIncomplete
        case (.sourceCapture, .changedWhileReading):
            .sourceCaptureChangedWhileReading
        case (.deliveryCapture, .itemsUnavailable):
            .deliveryCaptureItemsUnavailable
        case (.deliveryCapture, .incomplete):
            .deliveryCaptureIncomplete
        case (.deliveryCapture, .changedWhileReading):
            .deliveryCaptureChangedWhileReading
        }
    }

    func replaceSelection() async -> Outcome {
        guard accessibilityIsTrusted() else {
            return .refused(.accessibilityUnavailable, nil)
        }

        let target: TargetSnapshot
        switch await captureTarget() {
        case let .success(snapshot):
            target = snapshot
        case let .refused(reason, context):
            return .refused(reason, context)
        }

        let originalClipboard: PasteboardTransaction.Snapshot
        switch Self.captureClipboardSnapshot(
            stage: .sourceCapture,
            using: pasteboardTransaction.captureSnapshot
        ) {
        case let .captured(snapshot):
            originalClipboard = snapshot
        case let .refused(reason):
            return .refused(reason, target.context)
        }

        let modifiersReleased = await waitForShortcutModifiersRelease()
        guard modifiersReleased else {
            return .refused(.modifierReleaseTimedOut, target.context)
        }

        guard targetStillMatches(target) else {
            return .refused(.focusedElementUnavailable, target.context)
        }

        let copyProbe: PasteboardTransaction.Ownership
        switch pasteboardTransaction.stageCopyProbe(replacing: originalClipboard) {
        case let .staged(ownership):
            copyProbe = ownership
        case .sourceChanged:
            return .refused(.clipboardChanged, target.context)
        case .writeFailed:
            return .refused(.clipboardWriteFailed, target.context)
        }

        guard sendCommand(.copy, to: target.processIdentifier) else {
            return refusalAfterRestoring(
                originalClipboard,
                ownership: copyProbe,
                preferred: .copyEventUnavailable,
                context: target.context
            )
        }

        guard let copiedText = await waitForCopiedText(after: copyProbe) else {
            return refusalAfterRestoring(
                originalClipboard,
                ownership: copyProbe,
                preferred: .emptySelection,
                context: target.context
            )
        }

        let replacementText = DeterministicTextTransformer.transform(copiedText.value)
        let replacementOwnership: PasteboardTransaction.Ownership
        switch pasteboardTransaction.stageReplacement(
            replacementText,
            replacing: copiedText,
            original: originalClipboard
        ) {
        case let .staged(ownership):
            replacementOwnership = ownership
        case .sourceChanged:
            return .refused(.clipboardChanged, target.context)
        case .writeFailed:
            return .refused(.clipboardWriteFailed, target.context)
        }

        switch PasteDispatchGate.dispatch(
            revalidateTarget: { self.targetStillMatches(target) },
            clipboardStillOwned: {
                self.pasteboardTransaction.ownershipState(of: replacementOwnership) == .owned
            },
            send: { self.sendCommand(.paste, to: target.processIdentifier) }
        ) {
        case .targetChanged:
            return .resultCopied(target.context, .focusChanged)
        case .clipboardChanged:
            return .refused(.clipboardChanged, target.context)
        case .sendFailed:
            return .resultCopied(target.context, .pasteEventUnavailable)
        case .sent:
            break
        }

        try? await Task.sleep(for: .milliseconds(350))

        let restoration: ClipboardRestoration = switch pasteboardTransaction.restore(
            originalClipboard,
            ifOwnedBy: replacementOwnership
        ) {
        case .restored:
            .restored
        case .ownershipLost:
            .newerContentPreserved
        case .writeFailed:
            .failed
        }

        return .replacementSent(target.context, restoration)
    }

    func rewriteSelection(using task: RewriteTask) async -> Outcome {
        guard accessibilityIsTrusted() else {
            return .refused(.accessibilityUnavailable, nil)
        }

        let target: TargetSnapshot
        switch await captureTarget() {
        case let .success(snapshot):
            target = snapshot
        case let .refused(reason, context):
            return .refused(reason, context)
        }

        let originalClipboard: PasteboardTransaction.Snapshot
        switch Self.captureClipboardSnapshot(
            stage: .sourceCapture,
            using: pasteboardTransaction.captureSnapshot
        ) {
        case let .captured(snapshot):
            originalClipboard = snapshot
        case let .refused(reason):
            return .refused(reason, target.context)
        }

        let modifiersReleased = await waitForShortcutModifiersRelease()
        guard modifiersReleased else {
            return .refused(.modifierReleaseTimedOut, target.context)
        }
        guard targetStillMatches(target) else {
            return .refused(.selectionChanged, target.context)
        }

        let initialProbe: PasteboardTransaction.Ownership
        switch pasteboardTransaction.stageCopyProbe(replacing: originalClipboard) {
        case let .staged(ownership):
            initialProbe = ownership
        case .sourceChanged:
            return .refused(.clipboardChanged, target.context)
        case .writeFailed:
            return .refused(.clipboardWriteFailed, target.context)
        }

        guard targetStillMatches(target) else {
            return refusalAfterRestoring(
                originalClipboard,
                ownership: initialProbe,
                preferred: .selectionChanged,
                context: target.context
            )
        }
        guard pasteboardTransaction.ownershipState(of: initialProbe) == .owned else {
            return .refused(.clipboardChanged, target.context)
        }
        guard sendCommand(.copy, to: target.processIdentifier) else {
            return refusalAfterRestoring(
                originalClipboard,
                ownership: initialProbe,
                preferred: .copyEventUnavailable,
                context: target.context
            )
        }
        guard let initialSelection = await waitForCopiedText(after: initialProbe) else {
            return refusalAfterRestoring(
                originalClipboard,
                ownership: initialProbe,
                preferred: .emptySelection,
                context: target.context
            )
        }
        guard targetStillMatches(target) else {
            return refusalAfterRestoring(
                originalClipboard,
                copiedText: initialSelection,
                preferred: .selectionChanged,
                context: target.context
            )
        }

        switch pasteboardTransaction.restore(
            originalClipboard,
            replacing: initialSelection
        ) {
        case .restored, .ownershipLost:
            break
        case .writeFailed:
            return .refused(.clipboardRestoreFailed, target.context)
        }

        let generatedText: String
        do {
            generatedText = try await rewriteText(
                initialSelection.value,
                taskPrompt: task.prompt
            )
        } catch CodingPromptRewriteError.apiKeyMissing {
            return .refused(.apiKeyMissing, target.context)
        } catch CodingPromptRewriteError.keychainUnavailable {
            return .refused(.keychainUnavailable, target.context)
        } catch CodingPromptRewriteError.networkFailure {
            return .refused(.networkFailure, target.context)
        } catch CodingPromptRewriteError.apiFailure {
            return .refused(.apiFailure, target.context)
        } catch CodingPromptRewriteError.refusal {
            return .refused(.apiFailure, target.context)
        } catch CodingPromptRewriteError.emptyResponse {
            return .refused(.emptyModelResponse, target.context)
        } catch {
            return .refused(.apiFailure, target.context)
        }

        guard targetStillMatches(target) else {
            return .refused(.selectionChanged, target.context)
        }

        let deliveryClipboard: PasteboardTransaction.Snapshot
        switch Self.captureClipboardSnapshot(
            stage: .deliveryCapture,
            using: pasteboardTransaction.captureSnapshot
        ) {
        case let .captured(snapshot):
            deliveryClipboard = snapshot
        case let .refused(reason):
            return .refused(reason, target.context)
        }

        let deliveryProbe: PasteboardTransaction.Ownership
        switch pasteboardTransaction.stageCopyProbe(replacing: deliveryClipboard) {
        case let .staged(ownership):
            deliveryProbe = ownership
        case .sourceChanged:
            return .refused(.clipboardChanged, target.context)
        case .writeFailed:
            return .refused(.clipboardWriteFailed, target.context)
        }

        guard targetStillMatches(target) else {
            return refusalAfterRestoring(
                deliveryClipboard,
                ownership: deliveryProbe,
                preferred: .selectionChanged,
                context: target.context
            )
        }
        guard pasteboardTransaction.ownershipState(of: deliveryProbe) == .owned else {
            return .refused(.clipboardChanged, target.context)
        }
        guard sendCommand(.copy, to: target.processIdentifier) else {
            return refusalAfterRestoring(
                deliveryClipboard,
                ownership: deliveryProbe,
                preferred: .copyEventUnavailable,
                context: target.context
            )
        }
        guard let currentSelection = await waitForCopiedText(after: deliveryProbe) else {
            logger.notice(
                "Selection recheck failed reason=noCopiedText app=\(target.context.bundleIdentifier, privacy: .public)"
            )
            return refusalAfterRestoring(
                deliveryClipboard,
                ownership: deliveryProbe,
                preferred: .selectionChanged,
                context: target.context
            )
        }
        guard RewritePromptPolicy.selectionIsUnchanged(
            original: initialSelection.value,
            current: currentSelection.value
        ) else {
            logger.notice(
                "Selection recheck failed reason=textDiffers app=\(target.context.bundleIdentifier, privacy: .public)"
            )
            return refusalAfterRestoring(
                deliveryClipboard,
                copiedText: currentSelection,
                preferred: .selectionChanged,
                context: target.context
            )
        }

        let replacementOwnership: PasteboardTransaction.Ownership
        switch pasteboardTransaction.stageReplacement(
            generatedText,
            replacing: currentSelection,
            original: deliveryClipboard
        ) {
        case let .staged(ownership):
            replacementOwnership = ownership
        case .sourceChanged:
            return .refused(.clipboardChanged, target.context)
        case .writeFailed:
            return .refused(.clipboardWriteFailed, target.context)
        }

        switch PasteDispatchGate.dispatch(
            revalidateTarget: { self.targetStillMatches(target) },
            clipboardStillOwned: {
                self.pasteboardTransaction.ownershipState(of: replacementOwnership) == .owned
            },
            send: { self.sendCommand(.paste, to: target.processIdentifier) }
        ) {
        case .targetChanged:
            return refusalAfterRestoring(
                deliveryClipboard,
                ownership: replacementOwnership,
                preferred: .selectionChanged,
                context: target.context
            )
        case .clipboardChanged:
            return .refused(.clipboardChanged, target.context)
        case .sendFailed:
            return refusalAfterRestoring(
                deliveryClipboard,
                ownership: replacementOwnership,
                preferred: .pasteEventUnavailable,
                context: target.context
            )
        case .sent:
            break
        }

        try? await Task.sleep(for: .milliseconds(350))

        let restoration: ClipboardRestoration = switch pasteboardTransaction.restore(
            deliveryClipboard,
            ifOwnedBy: replacementOwnership
        ) {
        case .restored:
            .restored
        case .ownershipLost:
            .newerContentPreserved
        case .writeFailed:
            .failed
        }

        return .replacementSent(target.context, restoration)
    }

    private func accessibilityIsTrusted() -> Bool {
        #if DEBUG
        if let testHooks {
            return testHooks.accessibilityTrusted
        }
        #endif
        return AccessibilityPermission.isTrusted(prompt: false)
    }

    private func waitForShortcutModifiersRelease() async -> Bool {
        #if DEBUG
        if let testHooks {
            return testHooks.modifiersReleased()
        }
        #endif
        return await ModifierReleaseWaiter.wait(
            maximumChecks: 25,
            interval: .milliseconds(20),
            modifiersAreReleased: shortcutModifiersAreReleased
        )
    }

    private func sendCommand(
        _ command: CGKeyCommandSender.Command,
        to processIdentifier: pid_t
    ) -> Bool {
        #if DEBUG
        if let testHooks {
            return testHooks.sendCommand(command)
        }
        #endif
        return commandSender.send(command, to: processIdentifier)
    }

    private func rewriteText(
        _ selectedText: String,
        taskPrompt: String
    ) async throws -> String {
        #if DEBUG
        if let testHooks {
            return try await testHooks.rewrite(selectedText, taskPrompt)
        }
        #endif
        return try await codingPromptRewriter.rewrite(
            selectedText,
            taskPrompt: taskPrompt
        ).text
    }

    private func captureTarget() async -> CaptureResult {
        #if DEBUG
        if let testHooks {
            return .success(
                TargetSnapshot(
                    focusedElement: AXUIElementCreateSystemWide(),
                    processIdentifier: testHooks.processIdentifier,
                    context: testHooks.targetContext
                )
            )
        }
        #endif

        var firstFailure: TargetCaptureFailure?
        let (attempt, attempts) = await BoundedRetry.run(
            maximumAttempts: Self.captureMaximumAttempts,
            interval: Self.captureRetryInterval,
            attempt: { self.captureTargetOnce() },
            shouldRetry: { attempt in
                guard case let .failed(failure, _) = attempt else { return false }
                if firstFailure == nil { firstFailure = failure }
                return failure.isTransient
            }
        )

        switch attempt {
        case let .success(snapshot):
            if let firstFailure {
                logger.notice(
                    "Target captured after retry attempts=\(attempts, privacy: .public) first_step=\(firstFailure.logStep, privacy: .public) first_ax=\(firstFailure.accessibilityErrorCode, privacy: .public) app=\(snapshot.context.bundleIdentifier, privacy: .public)"
                )
            }
            return .success(snapshot)
        case let .failed(failure, context):
            logger.notice(
                "Target capture failed step=\(failure.logStep, privacy: .public) ax=\(failure.accessibilityErrorCode, privacy: .public) attempts=\(attempts, privacy: .public) app=\(context?.bundleIdentifier ?? "unknown", privacy: .public)"
            )
            return .refused(Self.refusal(for: failure), context)
        }
    }

    private static func refusal(for failure: TargetCaptureFailure) -> SafeRefusal {
        switch failure {
        case .focusedApplicationUnavailable, .focusedApplicationMismatch:
            .focusedApplicationUnavailable
        case .focusedElementUnavailable:
            .focusedElementUnavailable
        case .roleUnavailable, .secureStatusUnavailable:
            .secureStatusUnavailable
        case .secureControl:
            .secureControl
        }
    }

    /// Resolves the frontmost application's Accessibility element. The
    /// system-wide focused application must agree with the frontmost
    /// application when it is readable; when that read fails outright the
    /// frontmost application is queried directly instead.
    private func frontmostApplicationElement()
        -> Result<(element: AXUIElement, processIdentifier: pid_t), TargetCaptureFailure>
    {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier else {
            return .failure(.focusedApplicationUnavailable(.noValue))
        }

        let systemWide = AXUIElementCreateSystemWide()
        let (error, applicationElement) = copyElementAttribute(
            AXAttribute.focusedApplication,
            from: systemWide
        )
        guard let applicationElement else {
            return .success((AXUIElementCreateApplication(frontmostPID), frontmostPID))
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(applicationElement, &processIdentifier) == .success else {
            return .failure(.focusedApplicationUnavailable(error))
        }
        guard processIdentifier == frontmostPID else {
            return .failure(.focusedApplicationMismatch)
        }
        return .success((applicationElement, processIdentifier))
    }

    private func captureTargetOnce() -> CaptureAttempt {
        let applicationElement: AXUIElement
        let processIdentifier: pid_t
        switch frontmostApplicationElement() {
        case let .success(application):
            applicationElement = application.element
            processIdentifier = application.processIdentifier
        case let .failure(failure):
            return .failed(failure, nil)
        }

        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        let contextWithoutRole = Context(
            applicationName: runningApplication?.localizedName ?? "Unknown",
            bundleIdentifier: runningApplication?.bundleIdentifier ?? "unknown",
            role: "unknown",
            subrole: nil
        )

        let (focusError, focusedElement) = copyElementAttribute(
            AXAttribute.focusedElement,
            from: applicationElement
        )
        guard let focusedElement else {
            return .failed(.focusedElementUnavailable(focusError), contextWithoutRole)
        }

        let (roleError, roleValue) = copyAttribute(AXAttribute.role, from: focusedElement)
        guard let role = roleValue as? String else {
            return .failed(.roleUnavailable(roleError), contextWithoutRole)
        }

        let context = Context(
            applicationName: contextWithoutRole.applicationName,
            bundleIdentifier: contextWithoutRole.bundleIdentifier,
            role: role,
            subrole: copyStringAttribute(AXAttribute.subrole, from: focusedElement)
        )
        switch secureFieldDecision(for: focusedElement, context: context) {
        case .allowed:
            break
        case .secure:
            return .failed(.secureControl, context)
        case .unverifiable:
            return .failed(.secureStatusUnavailable, context)
        }

        return .success(
            TargetSnapshot(
                focusedElement: focusedElement,
                processIdentifier: processIdentifier,
                context: context
            )
        )
    }

    private func targetStillMatches(_ snapshot: TargetSnapshot) -> Bool {
        #if DEBUG
        if let testHooks {
            return testHooks.targetStillMatches()
        }
        #endif
        var status = targetMatchStatus(snapshot)
        var attempts = 1
        while status.isTransient, attempts < Self.revalidationMaximumAttempts {
            Thread.sleep(forTimeInterval: Self.revalidationRetryInterval)
            status = targetMatchStatus(snapshot)
            attempts += 1
        }
        guard status == .matches else {
            logger.notice(
                "Target revalidation failed reason=\(status.logReason, privacy: .public) attempts=\(attempts, privacy: .public) app=\(snapshot.context.bundleIdentifier, privacy: .public) role=\(snapshot.context.role, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func targetMatchStatus(_ snapshot: TargetSnapshot) -> TargetMatchStatus {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier else {
            return .applicationChanged
        }

        let applicationElement: AXUIElement
        switch frontmostApplicationElement() {
        case let .success(application):
            guard application.processIdentifier == snapshot.processIdentifier else {
                return .applicationChanged
            }
            applicationElement = application.element
        case .failure(.focusedApplicationMismatch):
            return .applicationChanged
        case let .failure(failure):
            return .readFailed(AXError(rawValue: failure.accessibilityErrorCode) ?? .failure)
        }

        let (focusError, focusedElement) = copyElementAttribute(
            AXAttribute.focusedElement,
            from: applicationElement
        )
        guard let focusedElement else {
            return .readFailed(focusError == .success ? .failure : focusError)
        }
        guard CFEqual(focusedElement, snapshot.focusedElement) else {
            return .elementChanged
        }

        let (roleError, roleValue) = copyAttribute(AXAttribute.role, from: focusedElement)
        guard let role = roleValue as? String else {
            return .readFailed(roleError == .success ? .failure : roleError)
        }
        let context = Context(
            applicationName: snapshot.context.applicationName,
            bundleIdentifier: snapshot.context.bundleIdentifier,
            role: role,
            subrole: copyStringAttribute(AXAttribute.subrole, from: focusedElement)
        )
        switch secureFieldDecision(for: focusedElement, context: context) {
        case .allowed:
            return .matches
        case .secure:
            return .secure
        case .unverifiable:
            return .readFailed(.cannotComplete)
        }
    }

    private func secureFieldDecision(
        for element: AXUIElement,
        context: Context
    ) -> AXSecureFieldDecision {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            AXAttribute.containsProtectedContent as CFString,
            &value
        )
        return AXSecureFieldCheck.decision(
            role: context.role,
            subrole: context.subrole,
            protectedContentStatus: AXSecureFieldCheck.protectedContentStatus(
                error: error,
                value: value
            )
        )
    }

    private func waitForCopiedText(
        after probe: PasteboardTransaction.Ownership
    ) async -> PasteboardTransaction.CopiedText? {
        for attempt in 0..<25 {
            if let copiedText = pasteboardTransaction.copiedText(after: probe) {
                return copiedText
            }
            guard attempt + 1 < 25 else {
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func refusalAfterRestoring(
        _ snapshot: PasteboardTransaction.Snapshot,
        ownership: PasteboardTransaction.Ownership,
        preferred refusal: SafeRefusal,
        context: Context
    ) -> Outcome {
        switch pasteboardTransaction.restore(snapshot, ifOwnedBy: ownership) {
        case .restored:
            return .refused(refusal, context)
        case .ownershipLost:
            return .refused(.clipboardChanged, context)
        case .writeFailed:
            return .refused(.clipboardRestoreFailed, context)
        }
    }

    private func refusalAfterRestoring(
        _ snapshot: PasteboardTransaction.Snapshot,
        copiedText: PasteboardTransaction.CopiedText,
        preferred refusal: SafeRefusal,
        context: Context
    ) -> Outcome {
        switch pasteboardTransaction.restore(snapshot, replacing: copiedText) {
        case .restored:
            return .refused(refusal, context)
        case .ownershipLost:
            return .refused(.clipboardChanged, context)
        case .writeFailed:
            return .refused(.clipboardRestoreFailed, context)
        }
    }

    private func shortcutModifiersAreReleased() -> Bool {
        let activeModifiers = GetCurrentKeyModifiers()
        let blockedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return activeModifiers & blockedModifiers == 0
    }

    private func copyElementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> (AXError, AXUIElement?) {
        let (error, value) = copyAttribute(attribute, from: element)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (error, nil)
        }
        return (error, (value as! AXUIElement))
    }

    private func copyStringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        copyAttribute(attribute, from: element).1 as? String
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        return (error, error == .success ? value : nil)
    }
}
