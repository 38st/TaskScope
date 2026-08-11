import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager: ObservableObject {
    enum RegistrationStatus: Equatable {
        case disabled
        case registered
        case conflict(OSStatus, previousShortcutRemainsActive: Bool)
        case unsupported

        var message: String {
            switch self {
            case .disabled: "Hotkey is disabled."
            case .registered: "Hotkey is registered."
            case .conflict(_, let previousShortcutRemainsActive):
                previousShortcutRemainsActive
                    ? "That shortcut is unavailable. The previous shortcut remains active."
                    : "That shortcut is unavailable. No global hotkey is currently active."
            case .unsupported: "Choose a supported key with at least one modifier."
            }
        }
    }

    static let shared = HotkeyManager()

    @Published var hotkeyEnabled: Bool {
        didSet {
            save()
            register()
        }
    }
    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32
    @Published private(set) var registrationStatus: RegistrationStatus = .disabled

    var onShow: (() -> Void)?

    nonisolated(unsafe) private var hotkeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var nextRegistrationID: UInt32 = 1

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "TaskScope.hotkey.v1"
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        let saved = defaults.dictionary(forKey: defaultsKey)
        hotkeyEnabled = saved?["enabled"] as? Bool ?? true
        keyCode = (saved?["keyCode"] as? UInt32) ?? UInt32(kVK_ANSI_T)
        modifiers = (saved?["modifiers"] as? UInt32) ?? UInt32(cmdKey | shiftKey)
    }

    deinit {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register() {
        guard hotkeyEnabled else {
            unregister()
            registrationStatus = .disabled
            return
        }
        guard Self.isSupported(keyCode: keyCode, modifiers: modifiers) else {
            registrationStatus = .unsupported
            return
        }
        _ = registerCandidate(keyCode: keyCode, modifiers: modifiers)
    }

    @discardableResult
    func updateShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard Self.isSupported(keyCode: keyCode, modifiers: modifiers) else {
            registrationStatus = .unsupported
            return false
        }

        if hotkeyEnabled, !registerCandidate(keyCode: keyCode, modifiers: modifiers) {
            return false
        }

        self.keyCode = keyCode
        self.modifiers = modifiers
        save()
        return true
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
    }

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode) ?? "Unsupported"
        return result
    }

    static func isSupported(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let supportedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return modifiers & supportedModifiers != 0 && keyName(for: keyCode) != nil
    }

    static func keyName(for code: UInt32) -> String? {
        switch Int(code) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Forward Delete"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: nil
        }
    }

    private func registerCandidate(keyCode: UInt32, modifiers: UInt32) -> Bool {
        installEventHandlerIfNeeded()
        let previousShortcutRemainsActive = hotkeyRef != nil
        let identifier = EventHotKeyID(signature: OSType(0x54534350), id: nextRegistrationID)
        nextRegistrationID &+= 1
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifierFlags(modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &candidate
        )
        guard status == noErr, let candidate else {
            registrationStatus = .conflict(
                status,
                previousShortcutRemainsActive: previousShortcutRemainsActive
            )
            return false
        }

        if let old = hotkeyRef {
            UnregisterEventHotKey(old)
        }
        hotkeyRef = candidate
        registrationStatus = .registered
        return true
    }

    private func carbonModifierFlags(_ flags: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        if flags & UInt32(cmdKey) != 0 { carbon |= UInt32(cmdKey) }
        if flags & UInt32(shiftKey) != 0 { carbon |= UInt32(shiftKey) }
        if flags & UInt32(optionKey) != 0 { carbon |= UInt32(optionKey) }
        if flags & UInt32(controlKey) != 0 { carbon |= UInt32(controlKey) }
        return carbon
    }

    private func save() {
        defaults.set([
            "enabled": hotkeyEnabled,
            "keyCode": keyCode,
            "modifiers": modifiers
        ], forKey: defaultsKey)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.onShow?()
                }
                return noErr
            },
            1,
            &eventSpec,
            pointer,
            &eventHandler
        )
    }
}
