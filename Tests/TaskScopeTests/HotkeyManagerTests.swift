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
        XCTAssertEqual(manager.registrationStatus, .unsupported)
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
