import Carbon.HIToolbox
import XCTest
@testable import TaskScope

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func testSupportedKeysHaveTruthfulNames() {
        XCTAssertEqual(HotkeyManager.keyName(for: UInt32(kVK_ANSI_T)), "T")
        XCTAssertEqual(HotkeyManager.keyName(for: UInt32(kVK_ANSI_7)), "7")
        XCTAssertEqual(HotkeyManager.keyName(for: UInt32(kVK_LeftArrow)), "←")
        XCTAssertEqual(HotkeyManager.keyName(for: UInt32(kVK_F12)), "F12")
        XCTAssertNil(HotkeyManager.keyName(for: UInt32.max))
    }

    func testShortcutRequiresSupportedKeyAndModifier() {
        XCTAssertTrue(
            HotkeyManager.isSupported(
                keyCode: UInt32(kVK_ANSI_T),
                modifiers: UInt32(cmdKey | shiftKey)
            )
        )
        XCTAssertFalse(
            HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_T), modifiers: 0)
        )
        XCTAssertFalse(
            HotkeyManager.isSupported(keyCode: UInt32.max, modifiers: UInt32(cmdKey))
        )
    }

    /// Shift or Option alone would intercept ordinary typing in every app;
    /// a global hotkey needs Command or Control.
    func testSingleShiftOrOptionIsNotAcceptedAsAGlobalHotkey() {
        let key = UInt32(kVK_ANSI_T)

        XCTAssertFalse(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(shiftKey)))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(optionKey)))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(shiftKey | optionKey)))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(controlKey)))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(cmdKey)))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(controlKey | shiftKey)))
        XCTAssertTrue(
            HotkeyManager.validationFailure(keyCode: key, modifiers: UInt32(shiftKey))?
                .contains("Command or Control") == true
        )
    }

    func testStandardAppShortcutsAreReservedWithoutRejectingTheDefault() {
        let keys = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
            kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
            kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
            kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
            kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
            kVK_ANSI_Z, kVK_ANSI_Comma
        ]
        for key in keys {
            XCTAssertTrue(
                HotkeyManager.validationFailure(keyCode: UInt32(key), modifiers: UInt32(cmdKey))?
                    .contains("is reserved by macOS. Choose another combination.") == true,
                "Key code \(key) must not hijack an app shortcut"
            )
        }
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey)),
            "⌘⇧Z (Redo) is reserved by macOS. Choose another combination."
        )
        XCTAssertNil(HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertNil(HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey)))
        XCTAssertNil(HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey)))
    }

    func testSystemReservedCombinationsAreRefusedWithAnExplanation() {
        let command = UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        let option = UInt32(optionKey)

        XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_Q), modifiers: command))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(kVK_Tab), modifiers: command))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(kVK_Space), modifiers: command))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(kVK_Space), modifiers: command | option))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_Q), modifiers: command | shift))
        XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_4), modifiers: command | shift))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey)))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_Space), modifiers: command | shift))
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_Q), modifiers: command),
            "⌘Q (Quit) is reserved by macOS. Choose another combination."
        )
    }

    func testRejectedShortcutExplainsItselfInTheRegistrationStatus() {
        let suite = "TaskScope.HotkeyManagerTests.reasons"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey")

        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(shiftKey)))
        XCTAssertTrue(manager.registrationStatus.message.contains("Command or Control"))
        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)))
        XCTAssertTrue(manager.registrationStatus.message.contains("reserved by macOS"))
        XCTAssertEqual(manager.modifiers, UInt32(cmdKey | shiftKey), "a rejected update leaves the configuration alone")
    }

    func testUnchangedShortcutIsNotReRegisteredAndAChangeUnregistersTheOldOneFirst() {
        let suite = "TaskScope.HotkeyManagerTests.backend"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeHotkeyBackend()
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)

        manager.register()
        manager.register()
        XCTAssertEqual(manager.registrationStatus, .registered)
        XCTAssertEqual(backend.events, ["register:T:768"], "an unchanged, registered shortcut must not be registered again")

        XCTAssertTrue(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))
        XCTAssertEqual(
            backend.events,
            ["register:T:768", "unregister:1", "register:K:4352"],
            "the old combination is unregistered before the new one is registered"
        )
        XCTAssertTrue(manager.isRegistered)
    }

    func testRefusedNewShortcutRestoresThePreviousOneAndSaysSo() {
        let suite = "TaskScope.HotkeyManagerTests.conflict"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeHotkeyBackend()
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
        manager.register()
        backend.refusedKeyCodes = [UInt32(kVK_ANSI_K)]

        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))

        XCTAssertEqual(
            manager.registrationStatus,
            .conflict(OSStatus(eventHotKeyExistsErr), previousShortcutRemainsActive: true)
        )
        XCTAssertEqual(
            backend.events,
            ["register:T:768", "unregister:1", "register:K:4352", "register:T:768"]
        )
        XCTAssertEqual(manager.keyCode, UInt32(kVK_ANSI_T))
        XCTAssertTrue(manager.isRegistered)
    }

    func testUnsupportedAtomicUpdateLeavesPreviousConfiguration() {
        let suite = "TaskScope.HotkeyManagerTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey")
        let originalKey = manager.keyCode
        let originalModifiers = manager.modifiers

        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32.max, modifiers: UInt32(cmdKey)))
        XCTAssertEqual(manager.keyCode, originalKey)
        XCTAssertEqual(manager.modifiers, originalModifiers)
        guard case .unsupported(let reason) = manager.registrationStatus else {
            return XCTFail("Expected an unsupported status, got \(manager.registrationStatus)")
        }
        XCTAssertTrue(reason.contains("supported key"), reason)
    }

    func testHotkeyIsNotAvailableWhileDisabled() {
        let suite = "TaskScope.HotkeyManagerTests.disabled"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeHotkeyBackend()
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
        manager.register()

        manager.hotkeyEnabled = false

        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(manager.registrationStatus, .disabled)
        XCTAssertEqual(backend.events.last, "unregister:1")
    }

    func testConflictMessageOnlyClaimsPreviousShortcutWhenOneRemainsActive() {
        XCTAssertEqual(
            HotkeyManager.RegistrationStatus.conflict(
                OSStatus(eventHotKeyExistsErr),
                previousShortcutRemainsActive: true
            ).message,
            "That shortcut is unavailable. The previous shortcut remains active."
        )
        XCTAssertEqual(
            HotkeyManager.RegistrationStatus.conflict(
                OSStatus(eventHotKeyExistsErr),
                previousShortcutRemainsActive: false
            ).message,
            "That shortcut is unavailable. No global hotkey is currently active."
        )
    }

    func testHandlerFailureMessagePreservesPreviousShortcutTruthfully() {
        XCTAssertEqual(
            HotkeyManager.RegistrationStatus.handlerUnavailable(
                OSStatus(eventNotHandledErr),
                previousShortcutRemainsActive: true
            ).message,
            "TaskScope could not activate the new hotkey handler. The previous shortcut remains active."
        )
        XCTAssertEqual(
            HotkeyManager.RegistrationStatus.handlerUnavailable(
                OSStatus(eventNotHandledErr),
                previousShortcutRemainsActive: false
            ).message,
            "TaskScope could not activate the global hotkey handler."
        )
    }
}

/// Records registration traffic and hands out distinct fake references.
@MainActor
private final class FakeHotkeyBackend: HotkeyRegistrationBackend {
    private(set) var events: [String] = []
    var refusedKeyCodes: Set<UInt32> = []
    private var nextReference = 1

    func installEventHandler(for manager: HotkeyManager) -> OSStatus {
        noErr
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (status: OSStatus, reference: EventHotKeyRef?) {
        events.append("register:\(HotkeyManager.keyName(for: keyCode) ?? "?"):\(modifiers)")
        guard !refusedKeyCodes.contains(keyCode) else {
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        let reference = OpaquePointer(bitPattern: nextReference)!
        nextReference += 1
        return (noErr, reference)
    }

    func unregister(_ reference: EventHotKeyRef) {
        events.append("unregister:\(Int(bitPattern: UnsafeRawPointer(reference)))")
    }
}
