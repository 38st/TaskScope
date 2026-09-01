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

        if inventory.contains(where: { process in
            guard process.pid != excludedPID,
                  let executablePath = process.executablePath,
                  executablePath.hasPrefix(mainExecutableDirectory) else {
                return false
            }
            return process.name == preset.mainProcessName
                || URL(fileURLWithPath: executablePath).lastPathComponent
                    == preset.mainProcessName
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
                .compactMap { process -> String? in
                    if helperNames.contains(process.name) {
                        return process.name
                    }
                    guard let executablePath = process.executablePath else {
                        return nil
                    }
                    let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
                    return helperNames.contains(executableName) ? executableName : nil
                }
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
