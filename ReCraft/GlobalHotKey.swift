import Carbon.HIToolbox
import Foundation

typealias GlobalHotKeyAction = @MainActor @Sendable () async -> Void

enum GlobalHotKeyRegistrationError: Error, Equatable, LocalizedError {
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)
    case unregisterHotKey(OSStatus)
    case removeHandler(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .installHandler(status):
            "InstallEventHandler failed with OSStatus \(status)"
        case let .registerHotKey(status):
            "RegisterEventHotKey failed with OSStatus \(status)"
        case let .unregisterHotKey(status):
            "UnregisterEventHotKey failed with OSStatus \(status)"
        case let .removeHandler(status):
            "RemoveEventHandler failed with OSStatus \(status)"
        }
    }
}

@MainActor
protocol GlobalHotKeyRegistration: AnyObject {
    func unregister() throws
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        binding: HotKeyBinding,
        identifier: UInt32,
        action: @escaping GlobalHotKeyAction
    ) throws -> any GlobalHotKeyRegistration
}

@MainActor
final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        binding: HotKeyBinding,
        identifier: UInt32,
        action: @escaping GlobalHotKeyAction
    ) throws -> any GlobalHotKeyRegistration {
        try CarbonGlobalHotKeyRegistration.make(
            binding: binding,
            identifier: identifier,
            action: action
        )
    }
}

private final class CarbonGlobalHotKeyRegistration: @unchecked Sendable,
    GlobalHotKeyRegistration
{
    private let identifier: UInt32
    private let action: GlobalHotKeyAction
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callbackRetainIsActive = false

    private init(identifier: UInt32, action: @escaping GlobalHotKeyAction) {
        self.identifier = identifier
        self.action = action
    }

    @MainActor
    static func make(
        binding: HotKeyBinding,
        identifier: UInt32,
        action: @escaping GlobalHotKeyAction
    ) throws -> CarbonGlobalHotKeyRegistration {
        precondition(Thread.isMainThread)

        let registration = CarbonGlobalHotKeyRegistration(
            identifier: identifier,
            action: action
        )
        let userData = Unmanaged.passRetained(registration).toOpaque()
        registration.callbackRetainIsActive = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonGlobalHotKeyHandler,
            1,
            &eventType,
            userData,
            &registration.eventHandler
        )

        guard handlerStatus == noErr else {
            registration.releaseCallbackRetain(userData: userData)
            throw GlobalHotKeyRegistrationError.installHandler(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x52435246), // "RCRF"
            id: identifier
        )
        let registrationStatus = RegisterEventHotKey(
            binding.virtualKey,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registration.hotKey
        )

        guard registrationStatus == noErr else {
            if let eventHandler = registration.eventHandler,
               RemoveEventHandler(eventHandler) == noErr {
                registration.eventHandler = nil
                registration.releaseCallbackRetain(userData: userData)
            }
            throw GlobalHotKeyRegistrationError.registerHotKey(registrationStatus)
        }

        return registration
    }

    @MainActor
    func unregister() throws {
        precondition(Thread.isMainThread)

        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            guard status == noErr else {
                throw GlobalHotKeyRegistrationError.unregisterHotKey(status)
            }
            self.hotKey = nil
        }

        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            guard status == noErr else {
                throw GlobalHotKeyRegistrationError.removeHandler(status)
            }
            self.eventHandler = nil
            releaseCallbackRetain(
                userData: Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    nonisolated fileprivate func handle(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == OSType(0x52435246),
              hotKeyID.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }

        let action = action
        Task { @MainActor in
            await action()
        }
        return noErr
    }

    @MainActor
    private func releaseCallbackRetain(userData: UnsafeMutableRawPointer) {
        guard callbackRetainIsActive else { return }
        callbackRetainIsActive = false
        Unmanaged<CarbonGlobalHotKeyRegistration>
            .fromOpaque(userData)
            .release()
    }
}

private let carbonGlobalHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let registration = Unmanaged<CarbonGlobalHotKeyRegistration>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return registration.handle(event: event)
}

@MainActor
enum HotKeyDisplayLabel {
    static func make(for binding: HotKeyBinding) -> String {
        binding.modifierGlyphs + keyLabel(for: binding.virtualKey)
    }

    static func make(for binding: HotKeyBinding, keyLabel: String) -> String {
        binding.modifierGlyphs + keyLabel.uppercased()
    }

    private static func keyLabel(for virtualKey: UInt32) -> String {
        if let translated = currentLayoutLabel(for: virtualKey), !translated.isEmpty {
            return translated.uppercased()
        }
        return fallbackLabels[virtualKey] ?? "?"
    }

    private static func currentLayoutLabel(for virtualKey: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(
                  source,
                  kTISPropertyUnicodeKeyLayoutData
              ) else {
            return nil
        }

        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var characterCount = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(virtualKey),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &characterCount,
            &characters
        )
        guard status == noErr, characterCount > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: characterCount)
    }

    private static let fallbackLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
    ]
}
