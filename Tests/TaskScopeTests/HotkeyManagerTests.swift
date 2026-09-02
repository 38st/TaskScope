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
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(cmdKey)))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: key, modifiers: UInt32(controlKey | shiftKey)))
        XCTAssertTrue(
            HotkeyManager.validationFailure(keyCode: key, modifiers: UInt32(shiftKey))?
                .contains("Command or Control") == true
        )
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
