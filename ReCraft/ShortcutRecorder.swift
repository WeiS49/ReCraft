import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let binding: HotKeyBinding
    let isRecording: Bool
    let isEnabled: Bool
    let onBeginRecording: @MainActor () -> Void
    let onEndRecording: @MainActor () -> Void
    let onCapture: @MainActor (HotKeyBinding) -> Void
    let onRejectedInput: @MainActor (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        update(button)
        return button
    }

    func updateNSView(
        _ nsView: ShortcutRecorderButton,
        context: Context
    ) {
        update(nsView)
    }

    static func dismantleNSView(
        _ nsView: ShortcutRecorderButton,
        coordinator: Void
    ) {
        nsView.stopRecordingIfNeeded()
    }

    private func update(_ button: ShortcutRecorderButton) {
        button.configure(
            title: displayTitle,
            accessibilityValue: accessibilityValue,
            isRecording: isRecording,
            isEnabled: isEnabled,
            onBeginRecording: onBeginRecording,
            onEndRecording: onEndRecording,
            onCapture: onCapture,
            onRejectedInput: onRejectedInput
        )
    }

    private var displayTitle: String {
        if isRecording {
            return "Type shortcut…"
        }
        guard HotKeyBinding.supportedLetterKeys.contains(binding.virtualKey),
              binding.modifiers.nonzeroBitCount >= 2 else {
            return "Record Shortcut"
        }
        return HotKeyDisplayLabel.make(for: binding)
    }

    private var accessibilityValue: String {
        guard HotKeyBinding.supportedLetterKeys.contains(binding.virtualKey),
              binding.modifiers.nonzeroBitCount >= 2 else {
            return "Not set"
        }
        return HotKeyDisplayLabel.make(for: binding)
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    private var recording = false
    private var onBeginRecording: (@MainActor () -> Void)?
    private var onEndRecording: (@MainActor () -> Void)?
    private var onCapture: (@MainActor (HotKeyBinding) -> Void)?
    private var onRejectedInput: (@MainActor (String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        focusRingType = .exterior
        target = self
        action = #selector(focusRecorder)
        setAccessibilityLabel("Task shortcut")
        setAccessibilityHelp(
            "Press an A through Z key with at least two modifier keys. Press Escape to stop recording."
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    func configure(
        title: String,
        accessibilityValue: String,
        isRecording: Bool,
        isEnabled: Bool,
        onBeginRecording: @escaping @MainActor () -> Void,
        onEndRecording: @escaping @MainActor () -> Void,
        onCapture: @escaping @MainActor (HotKeyBinding) -> Void,
        onRejectedInput: @escaping @MainActor (String) -> Void
    ) {
        if recording,
           !isRecording,
           window?.firstResponder === self {
            _ = window?.makeFirstResponder(nil)
        }
        self.title = title
        self.isEnabled = isEnabled
        recording = isRecording
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
        self.onCapture = onCapture
        self.onRejectedInput = onRejectedInput
        setAccessibilityValue(accessibilityValue)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        recording = true
        onBeginRecording?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            stopRecordingIfNeeded()
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Tab) {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            _ = window?.makeFirstResponder(nil)
            return
        }

        let virtualKey = UInt32(event.keyCode)
        guard HotKeyBinding.supportedLetterKeys.contains(virtualKey) else {
            NSSound.beep()
            onRejectedInput?("Use an A–Z key with at least two modifier keys.")
            return
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers.nonzeroBitCount >= 2 else {
            NSSound.beep()
            onRejectedInput?("Use at least two modifier keys.")
            return
        }

        onCapture?(
            HotKeyBinding(
                virtualKey: virtualKey,
                modifiers: modifiers
            )
        )
    }

    func stopRecordingIfNeeded() {
        guard recording else { return }
        recording = false
        onEndRecording?()
    }

    @objc
    private func focusRecorder() {
        window?.makeFirstResponder(self)
    }

    @objc
    private func windowDidResignKey() {
        if window?.firstResponder === self {
            _ = window?.makeFirstResponder(nil)
        }
        stopRecordingIfNeeded()
    }

    private func carbonModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= HotKeyBinding.commandModifier
        }
        if flags.contains(.control) {
            modifiers |= HotKeyBinding.controlModifier
        }
        if flags.contains(.option) {
            modifiers |= HotKeyBinding.optionModifier
        }
        if flags.contains(.shift) {
            modifiers |= HotKeyBinding.shiftModifier
        }
        return modifiers
    }
}

struct SettingsWindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> SettingsWindowCloseObservingView {
        let view = SettingsWindowCloseObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(
        _ nsView: SettingsWindowCloseObservingView,
        context: Context
    ) {
        nsView.onClose = onClose
    }
}

@MainActor
final class SettingsWindowCloseObservingView: NSView {
    var onClose: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowWillClose() {
        onClose?()
    }
}
