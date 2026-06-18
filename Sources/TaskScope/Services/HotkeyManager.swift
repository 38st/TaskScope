import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var hotkeyEnabled: Bool {
        didSet { save() }
    }
    @Published var keyCode: UInt32 {
        didSet { save() }
    }
    @Published var modifiers: UInt32 {
        didSet { save() }
    }

    var onToggle: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let defaultsKey = "TaskScope.hotkey.v1"

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey)
        hotkeyEnabled = saved?["enabled"] as? Bool ?? true
        keyCode = (saved?["keyCode"] as? UInt32) ?? UInt32(kVK_ANSI_T)
        modifiers = (saved?["modifiers"] as? UInt32) ?? UInt32(cmdKey | shiftKey)
    }

    func register() {
        guard hotkeyEnabled else {
            unregister()
            return
        }
        unregister()
        installEventHandlerIfNeeded()

        let hotkeyId = EventHotKeyID(signature: OSType(0x544f4750), id: 1)
        let carbonMods = carbonModifierFlags(modifiers)
        let status = RegisterEventHotKey(keyCode, carbonMods, hotkeyId, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr {
            print("Hotkey registration failed: \(status)")
        }
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
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
        UserDefaults.standard.set([
            "enabled": hotkeyEnabled,
            "keyCode": keyCode,
            "modifiers": modifiers
        ], forKey: defaultsKey)
        register()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onToggle?()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandler
        )
    }

    var displayString: String {
        var result = ""
        let mods = modifiers
        if mods & UInt32(controlKey) != 0 { result += "⌃" }
        if mods & UInt32(optionKey) != 0 { result += "⌥" }
        if mods & UInt32(shiftKey) != 0 { result += "⇧" }
        if mods & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyName(for: keyCode)
        return result
    }

    private func keyName(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        default: return "?"
        }
    }
}
