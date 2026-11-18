#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Debug-only diagnostic. Samples Accessibility *metadata* (error codes,
/// roles, element identity stability) of the frontmost application and writes
/// it to the file given by `--focus-probe-output`. It never reads values,
/// selections, titles, or the pasteboard, and it is compiled out of Release.
@MainActor
enum DebugFocusProbe {
    private static var previousElement: AXUIElement?
    private static var previousPID: pid_t = 0

    static func startIfRequested(arguments: [String]) {
        guard let flagIndex = arguments.firstIndex(of: "--focus-probe-output"),
              arguments.indices.contains(flagIndex + 1) else {
            return
        }
        let outputURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        let sampleCount = value(after: "--focus-probe-samples", in: arguments) ?? 120
        let intervalMilliseconds = value(after: "--focus-probe-interval-ms", in: arguments) ?? 250

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return }

        Task { @MainActor in
            let start = ContinuousClock.now
            let hudEvery = value(after: "--focus-probe-hud-every", in: arguments)
            var presenters: [FeedbackPresenter] = []
            for index in 0..<max(1, min(sampleCount, 2_000)) {
                if let hudEvery, hudEvery > 0, index % hudEvery == 0 {
                    // Mimic the task path: a fresh HUD is ordered front right
                    // before the focus query.
                    let presenter = FeedbackPresenter()
                    presenters.append(presenter)
                    presenter.show("Probe HUD", kind: .success)
                    handle.write(Data("hud-shown\n".utf8))
                }
                let elapsed = ContinuousClock.now - start
                let line = "t=\(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000) " + sample() + "\n"
                handle.write(Data(line.utf8))
                try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
            try? handle.close()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Posts synthetic global shortcut presses (Control-Option-Command plus
    /// the given virtual key) so the registered Carbon hotkey path can be
    /// exercised end to end without a person at the keyboard.
    static func postHotKeysIfRequested(arguments: [String]) {
        guard let keyCode = value(after: "--debug-post-hotkey", in: arguments) else {
            return
        }
        let delay = value(after: "--debug-post-delay-ms", in: arguments) ?? 3_000
        let count = value(after: "--debug-post-count", in: arguments) ?? 1
        let gap = value(after: "--debug-post-gap-ms", in: arguments) ?? 4_000
        let holdModifiers = value(after: "--debug-post-hold-ms", in: arguments) ?? 0

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            let activateBundleID = stringValue(after: "--debug-activate", in: arguments)
            let leads = (stringValue(after: "--debug-activate-leads-ms", in: arguments) ?? "300")
                .split(separator: ",").compactMap { Int($0) }
            for index in 0..<max(1, min(count, 50)) {
                if let activateBundleID, !leads.isEmpty {
                    // Leave the target, come back, then press after a chosen
                    // lead time to exercise shortcuts right after activation.
                    NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.apple.finder"
                    ).first?.activate()
                    try? await Task.sleep(for: .milliseconds(700))
                    NSRunningApplication.runningApplications(
                        withBundleIdentifier: activateBundleID
                    ).first?.activate()
                    let lead = leads[index % leads.count]
                    try? await Task.sleep(for: .milliseconds(lead))
                    Logger(subsystem: "com.local.ReCraftClipboardSpike", category: "Probe")
                        .notice("Probe press lead_ms=\(lead, privacy: .public)")
                }
                await postHotKey(CGKeyCode(keyCode), holdModifiersMilliseconds: holdModifiers)
                if index + 1 < count {
                    try? await Task.sleep(for: .milliseconds(gap))
                }
            }
        }
    }

    private static func postHotKey(
        _ keyCode: CGKeyCode,
        holdModifiersMilliseconds: Int
    ) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let modifierKeys: [CGKeyCode] = [59, 58, 55] // control, option, command

        var activeFlags: CGEventFlags = []
        for (modifier, flag) in zip(modifierKeys, [CGEventFlags.maskControl, .maskAlternate, .maskCommand]) {
            activeFlags.insert(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: modifier, keyDown: true)
            event?.flags = activeFlags
            event?.post(tap: .cghidEventTap)
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(40))
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(holdModifiersMilliseconds))
        for (modifier, flag) in zip(modifierKeys, [CGEventFlags.maskControl, .maskAlternate, .maskCommand]).reversed() {
            activeFlags.remove(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: modifier, keyDown: false)
            event?.flags = activeFlags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func stringValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func value(after flag: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return Int(arguments[index + 1])
    }

    private static func sample() -> String {
        var fields: [String] = []
        fields.append("trusted=\(AXIsProcessTrusted())")

        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontPID = frontmost?.processIdentifier ?? 0
        fields.append("front=\(frontmost?.bundleIdentifier ?? "nil")")

        let systemWide = AXUIElementCreateSystemWide()
        let (systemAppError, systemApp) = element("AXFocusedApplication", of: systemWide)
        var systemAppPID: pid_t = 0
        if let systemApp { AXUIElementGetPid(systemApp, &systemAppPID) }
        fields.append("sysApp=\(systemAppError.rawValue)")
        fields.append("sysAppIsFront=\(systemApp != nil && systemAppPID == frontPID)")

        let (systemFocusError, systemFocus) = element("AXFocusedUIElement", of: systemWide)
        fields.append("sysFocus=\(systemFocusError.rawValue)")

        guard frontPID != 0 else {
            return fields.joined(separator: " ")
        }
        let application = AXUIElementCreateApplication(frontPID)
        let (focusError, focus) = element("AXFocusedUIElement", of: application)
        fields.append("appFocus=\(focusError.rawValue)")

        guard let focus else {
            previousElement = nil
            previousPID = frontPID
            return fields.joined(separator: " ")
        }

        if let systemFocus {
            fields.append("sysFocusEqual=\(CFEqual(systemFocus, focus))")
        }
        if previousPID == frontPID, let previousElement {
            fields.append("sameAsPrevious=\(CFEqual(previousElement, focus))")
        } else {
            fields.append("sameAsPrevious=first")
        }
        previousElement = focus
        previousPID = frontPID

        let (roleError, role) = string("AXRole", of: focus)
        fields.append("role=\(role ?? "err\(roleError.rawValue)")")
        let (subroleError, subrole) = string("AXSubrole", of: focus)
        fields.append("subrole=\(subrole ?? "err\(subroleError.rawValue)")")

        var protectedValue: CFTypeRef?
        let protectedError = AXUIElementCopyAttributeValue(
            focus,
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            &protectedValue
        )
        fields.append("protected=\(protectedError.rawValue)")

        var settable: DarwinBoolean = false
        let settableError = AXUIElementIsAttributeSettable(
            focus,
            "AXSelectedText" as CFString,
            &settable
        )
        fields.append("selTextSettable=\(settableError == .success ? String(settable.boolValue) : "err\(settableError.rawValue)")")
        return fields.joined(separator: " ")
    }

    private static func element(
        _ attribute: String,
        of element: AXUIElement
    ) -> (AXError, AXUIElement?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (error, nil)
        }
        return (error, (value as! AXUIElement))
    }

    private static func string(
        _ attribute: String,
        of element: AXUIElement
    ) -> (AXError, String?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value as? String)
    }
}
#endif
