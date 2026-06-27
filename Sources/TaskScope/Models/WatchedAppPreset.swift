import Foundation

struct UserLaunchAgentJob: Codable, Equatable, Hashable {
    var label: String
    var plistPath: String
}

struct SystemLaunchDaemonJob: Codable, Equatable, Hashable {
    var label: String
    var plistPath: String
    var processName: String
    var servicePort: Int?
}

struct WatchedAppPreset: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var mainProcessName: String
    var helperProcessNames: [String]
    var protectedProcessNames: [String]
    var appPath: String
    var userLaunchAgentJobs: [UserLaunchAgentJob] = []
    var systemLaunchDaemonJobs: [SystemLaunchDaemonJob] = []
    var notificationsEnabled: Bool = true
    var priority: Int = 0

    var allProcessNames: [String] {
        [mainProcessName] + helperProcessNames + protectedProcessNames
    }

    var killableNames: [String] {
        [mainProcessName] + helperProcessNames
    }

    var lifecycleUserLaunchAgentJobs: [UserLaunchAgentJob] {
        if usesGlobalProtectLifecycle {
            return Self.globalProtectUserLaunchAgentJobs
        }
        return userLaunchAgentJobs
    }

    var lifecycleSystemLaunchDaemonJobs: [SystemLaunchDaemonJob] {
        if usesGlobalProtectLifecycle {
            return Self.globalProtectSystemLaunchDaemonJobs
        }
        return systemLaunchDaemonJobs
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        mainProcessName: String,
        helperProcessNames: [String],
        protectedProcessNames: [String],
        appPath: String,
        userLaunchAgentJobs: [UserLaunchAgentJob] = [],
        systemLaunchDaemonJobs: [SystemLaunchDaemonJob] = [],
        notificationsEnabled: Bool = true,
        priority: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.mainProcessName = mainProcessName
        self.helperProcessNames = helperProcessNames
        self.protectedProcessNames = protectedProcessNames
        self.appPath = appPath
        self.userLaunchAgentJobs = userLaunchAgentJobs
        self.systemLaunchDaemonJobs = systemLaunchDaemonJobs
        self.notificationsEnabled = notificationsEnabled
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decode(String.self, forKey: .displayName)
        mainProcessName = try container.decode(String.self, forKey: .mainProcessName)
        helperProcessNames = try container.decodeIfPresent([String].self, forKey: .helperProcessNames) ?? []
        protectedProcessNames = try container.decodeIfPresent([String].self, forKey: .protectedProcessNames) ?? []
        appPath = try container.decode(String.self, forKey: .appPath)
        userLaunchAgentJobs = try container.decodeIfPresent([UserLaunchAgentJob].self, forKey: .userLaunchAgentJobs) ?? []
        systemLaunchDaemonJobs = try container.decodeIfPresent([SystemLaunchDaemonJob].self, forKey: .systemLaunchDaemonJobs) ?? []
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    static let globalProtect = WatchedAppPreset(
        displayName: "GlobalProtect",
        mainProcessName: "GlobalProtect",
        helperProcessNames: ["PanGPA"],
        protectedProcessNames: ["PanGPS"],
        appPath: "/Applications/GlobalProtect.app",
        userLaunchAgentJobs: globalProtectUserLaunchAgentJobs,
        systemLaunchDaemonJobs: globalProtectSystemLaunchDaemonJobs
    )

    private var usesGlobalProtectLifecycle: Bool {
        mainProcessName == "GlobalProtect"
            && appPath == "/Applications/GlobalProtect.app"
    }

    func matchesLookupName(_ name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }

        return displayName.caseInsensitiveCompare(normalizedName) == .orderedSame
            || mainProcessName.caseInsensitiveCompare(normalizedName) == .orderedSame
    }

    private static let globalProtectUserLaunchAgentJobs = [
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangpa",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist"
        )
    ]

    private static let globalProtectSystemLaunchDaemonJobs = [
        SystemLaunchDaemonJob(
            label: "com.paloaltonetworks.gp.pangpsd",
            plistPath: "/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist",
            processName: "PanGPS",
            servicePort: 4767
        )
    ]
}

struct WatchedAppSnapshot: Equatable {
    var preset: WatchedAppPreset
    var runningNames: Set<String>

    var isMainRunning: Bool {
        runningNames.contains(preset.mainProcessName)
    }

    var helpersRunning: [String] {
        preset.helperProcessNames.filter { runningNames.contains($0) }
    }

    var protectedRunning: [String] {
        preset.protectedProcessNames.filter { runningNames.contains($0) }
    }

    var hasHelpers: Bool {
        !helpersRunning.isEmpty
    }

    var hasAny: Bool {
        !runningNames.isEmpty
    }

    var detail: String {
        var names: [String] = []
        if isMainRunning {
            names.append(preset.mainProcessName)
        }
        names.append(contentsOf: helpersRunning)
        names.append(contentsOf: protectedRunning)
        return names.isEmpty ? "No watched processes" : names.joined(separator: ", ")
    }
}

extension WatchedAppSnapshot: Identifiable {
    var id: UUID { preset.id }
}

extension Array where Element == WatchedAppSnapshot {
    var aggregateStatus: ProcessStatus {
        if contains(where: { $0.isMainRunning }) {
            return .watchedRunning
        }
        if contains(where: { $0.hasHelpers }) {
            return .helpersOnly
        }
        return .idle
    }

    var aggregateDetail: String {
        let running = compactMap { snap -> String? in
            guard snap.hasAny else { return nil }
            return snap.detail
        }
        return running.isEmpty ? "No watched processes" : running.joined(separator: " · ")
    }
}
