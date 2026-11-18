import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct PasteDispatchGate {
    enum Result: Equatable {
        case sent
        case targetChanged
        case clipboardChanged
        case sendFailed
    }

    @MainActor
    static func dispatch(
        revalidateTarget: () -> Bool,
        clipboardStillOwned: () -> Bool,
        send: () -> Bool
    ) -> Result {
        guard revalidateTarget() else {
            return .targetChanged
        }
        guard clipboardStillOwned() else {
            return .clipboardChanged
        }
        return send() ? .sent : .sendFailed
    }
}

struct ModifierReleaseWaiter {
    @MainActor
    static func wait(
        maximumChecks: Int,
        interval: Duration,
        modifiersAreReleased: @MainActor () -> Bool
    ) async -> Bool {
        precondition(maximumChecks > 0)

        for checkIndex in 0..<maximumChecks {
            if modifiersAreReleased() {
                return true
            }
            guard checkIndex + 1 < maximumChecks else {
                break
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return false
            }
        }
        return false
    }
}

struct CGKeyCommandSender {
    enum Command {
        case copy
        case paste

        fileprivate var virtualKey: CGKeyCode {
            switch self {
            case .copy:
                CGKeyCode(kVK_ANSI_C)
            case .paste:
                CGKeyCode(kVK_ANSI_V)
            }
        }
    }

    func send(_ command: Command, to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: command.virtualKey,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: command.virtualKey,
                  keyDown: false
              ) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
}
