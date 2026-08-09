import XCTest
@testable import TaskScope

@available(macOS 13.0, *)
final class TaskScopeIntentsTests: XCTestCase {
    func testShortcutsDoNotRequestForegroundActivation() {
        XCTAssertFalse(RefreshTaskScopeIntent.openAppWhenRun)
        XCTAssertFalse(OpenWatchedAppIntent.openAppWhenRun)
        XCTAssertFalse(StopWatchedAppIntent.openAppWhenRun)
    }

    private let suiteName = "TaskScope.TaskScopeIntentsTests"
    private let key = "watched-presets-intent-tests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCatalogUsesDefaultPresetOnlyWhenNoPayloadExists() {
        let catalog = WatchedPresetCatalog(suiteName: suiteName, key: key)
        XCTAssertEqual(catalog.entities().map(\.displayName), ["GlobalProtect"])

        defaults.set(Data([0xFE, 0xED]), forKey: key)
        XCTAssertTrue(catalog.entities().isEmpty)
    }

    func testQueryResolvesStableIdentifiersAndSearchesNames() async throws {
        let alpha = preset(name: "Alpha")
        let beta = preset(name: "Beta Client")
        defaults.set(try JSONEncoder().encode([alpha, beta]), forKey: key)
        let query = WatchedPresetEntityQuery(
            catalog: WatchedPresetCatalog(suiteName: suiteName, key: key)
        )

        let resolved = try await query.entities(for: [beta.id, UUID()])
        let searched = try await query.entities(matching: "client")
        let suggested = try await query.suggestedEntities()

        XCTAssertEqual(resolved.map(\.id), [beta.id])
        XCTAssertEqual(searched.map(\.id), [beta.id])
        XCTAssertEqual(suggested.map(\.id), [alpha.id, beta.id])
    }

    func testDialogPreservesSuccessAndLabelsRejectedAndFailedResults() {
        XCTAssertEqual(
            TaskScopeIntentDialog.message(
                for: TaskScopeCommandResult(status: .completed, message: "Opened Alpha."),
                action: "open Alpha"
            ),
            "Opened Alpha."
        )
        XCTAssertEqual(
            TaskScopeIntentDialog.message(
                for: TaskScopeCommandResult(status: .rejected, message: "No matching preset."),
                action: "open Alpha"
            ),
            "Couldn’t open Alpha: No matching preset."
        )
        XCTAssertEqual(
            TaskScopeIntentDialog.message(
                for: TaskScopeCommandResult(status: .failed, message: "Lifecycle incomplete."),
                action: "stop Alpha"
            ),
            "Failed to stop Alpha: Lifecycle incomplete."
        )
    }

    func testRejectedAndFailedCommandsThrowForShortcuts() throws {
        XCTAssertEqual(
            try TaskScopeIntentDialog.successMessage(
                for: TaskScopeCommandResult(status: .completed, message: "Opened Alpha."),
                action: "open Alpha"
            ),
            "Opened Alpha."
        )
        XCTAssertThrowsError(
            try TaskScopeIntentDialog.successMessage(
                for: TaskScopeCommandResult(status: .rejected, message: "No matching preset."),
                action: "open Alpha"
            )
        )
        XCTAssertThrowsError(
            try TaskScopeIntentDialog.successMessage(
                for: TaskScopeCommandResult(status: .failed, message: "Lifecycle incomplete."),
                action: "stop Alpha"
            )
        )
    }

    private func preset(name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: "\(name)Process",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name).app"
        )
    }
}
