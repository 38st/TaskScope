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
        let mainExecutableDirectory = preset.mainExecutableDirectory
        let bundleContentsDirectory = preset.bundleContentsDirectory

        let mainProcessPIDs = Set(
            inventory.lazy
                .filter { process in
                    guard process.pid != excludedPID,
                          let executablePath = process.executablePath,
                          executablePath.hasPrefix(mainExecutableDirectory) else {
                        return false
                    }
                    return process.name == preset.mainProcessName
                        || URL(fileURLWithPath: executablePath).lastPathComponent
                            == preset.mainProcessName
                }
                .map(\.pid)
        )
        if !mainProcessPIDs.isEmpty {
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

        // A protected name identifies the protected *system* daemon only when the
        // process actually runs as root. GlobalProtect's optional per-user
        // `pangps` agent runs a binary that is also named PanGPS; reporting it as
        // the system daemon would make Keep Off claim a service is available
        // when only the user agent is, and would hide that the user agent is
        // still running. An unknown uid is never promoted to root.
        let protectedNames = Set(preset.protectedProcessNames)
        var unprivilegedProtectedNames = Set<String>()
        for process in inventory
        where process.pid != excludedPID && protectedNames.contains(process.name) {
            if process.uid == 0 {
                runningNames.insert(process.name)
            } else {
                unprivilegedProtectedNames.insert(process.name)
            }
        }

        return WatchedAppSnapshot(
            preset: preset,
            runningNames: runningNames,
            mainProcessPIDs: mainProcessPIDs,
            unprivilegedProtectedNames: unprivilegedProtectedNames
        )
    }
}
