import Foundation

/// Builds watched-preset status from an immutable process inventory. It has no
/// polling, notification, persistence, or presentation responsibilities.
struct WatchedSnapshotBuilder: Sendable {
    let excludedPID: Int32

    func snapshots(
        for presets: [WatchedAppPreset],
        in inventory: [AppProcess]
    ) -> [WatchedAppSnapshot] {
        presets.map { snapshot(for: $0, in: inventory) }
    }

    func snapshot(
        for preset: WatchedAppPreset,
        in inventory: [AppProcess]
    ) -> WatchedAppSnapshot {
        var runningNames = Set<String>()
        let mainExecutableDirectory = URL(fileURLWithPath: preset.appPath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .standardizedFileURL.path + "/"
        let bundleContentsDirectory = URL(fileURLWithPath: preset.appPath, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .standardizedFileURL.path + "/"

        if inventory.contains(where: {
            $0.pid != excludedPID
                && $0.name == preset.mainProcessName
                && $0.executablePath?.hasPrefix(mainExecutableDirectory) == true
        }) {
            runningNames.insert(preset.mainProcessName)
        }

        let helperNames = Set(preset.helperProcessNames)
        runningNames.formUnion(
            inventory.lazy
                .filter {
                    $0.pid != excludedPID
                        && $0.executablePath?.hasPrefix(bundleContentsDirectory) == true
                }
                .map(\.name)
                .filter { helperNames.contains($0) }
        )

        let protectedNames = Set(preset.protectedProcessNames)
        runningNames.formUnion(
            inventory.lazy
                .filter { $0.pid != excludedPID }
                .map(\.name)
                .filter { protectedNames.contains($0) }
        )

        return WatchedAppSnapshot(preset: preset, runningNames: runningNames)
    }
}
