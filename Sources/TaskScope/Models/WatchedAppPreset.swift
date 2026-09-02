import Foundation

struct UserLaunchAgentJob: Codable, Equatable, Hashable, Sendable {
    var label: String
    var plistPath: String
    var isRequired: Bool

    init(label: String, plistPath: String, isRequired: Bool = true) {
        self.label = label
        self.plistPath = plistPath
        self.isRequired = isRequired
    }

    private enum CodingKeys: String, CodingKey {
        case label, plistPath, isRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        plistPath = try container.decode(String.self, forKey: .plistPath)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? true
    }
}

struct SystemLaunchDaemonJob: Codable, Equatable, Hashable, Sendable {
    var label: String
    var plistPath: String
    var processName: String
    var servicePort: Int?
}

struct WatchedAppPreset: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String
    var mainProcessName: String
    var helperProcessNames: [String]
    var protectedProcessNames: [String]
    var appPath: String
    var userLaunchAgentJobs: [UserLaunchAgentJob] = []
    var systemLaunchDaemonJobs: [SystemLaunchDaemonJob] = []
    var notificationsEnabled: Bool = true

    var allProcessNames: [String] {
        [mainProcessName] + helperProcessNames + protectedProcessNames
    }

    var killableNames: [String] {
        [mainProcessName] + helperProcessNames
    }

    var lifecycleUserLaunchAgentJobs: [UserLaunchAgentJob] {
        if hasSupportedGlobalProtectIdentity {
            return Self.globalProtectUserLaunchAgentJobs
        }
        return userLaunchAgentJobs
    }

    var lifecycleSystemLaunchDaemonJobs: [SystemLaunchDaemonJob] {
        if hasSupportedGlobalProtectIdentity {
            return Self.globalProtectSystemLaunchDaemonJobs
        }
        return []
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
        notificationsEnabled: Bool = true
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
    }

    /// Fixed so the built-in preset keeps one identity across launches. It used to
    /// take the `UUID()` default, which a `static let` mints fresh per process, and
    /// the seeded default is never written to storage — so any Shortcut bound to
    /// this preset resolved to nothing after a relaunch.
    static let globalProtectID = UUID(uuidString: "1B0E5C1E-6B0A-4F2E-9E7B-2C3A5D8F41A7")!

    static let globalProtect = WatchedAppPreset(
        id: globalProtectID,
        displayName: "GlobalProtect",
        mainProcessName: "GlobalProtect",
        helperProcessNames: ["PanGPA"],
        protectedProcessNames: ["PanGPS"],
        appPath: "/Applications/GlobalProtect.app",
        userLaunchAgentJobs: globalProtectUserLaunchAgentJobs,
        systemLaunchDaemonJobs: globalProtectSystemLaunchDaemonJobs
    )

    var hasCanonicalGlobalProtectIdentity: Bool {
        hasFixedGlobalProtectFields
            && userLaunchAgentJobs == Self.globalProtectUserLaunchAgentJobs
            && systemLaunchDaemonJobs == Self.globalProtectSystemLaunchDaemonJobs
    }

    /// Recognizes the previous built-in payload so a trusted schema migration can
    /// add the optional per-user PanGPS agent without putting preferences into
    /// recovery mode. No custom identity or privileged field is accepted here.
    var hasSupportedGlobalProtectIdentity: Bool {
        hasFixedGlobalProtectFields
            && [
                Self.globalProtectUserLaunchAgentJobs,
                Self.legacyGlobalProtectUserLaunchAgentJobs
            ].contains(userLaunchAgentJobs)
            && systemLaunchDaemonJobs == Self.globalProtectSystemLaunchDaemonJobs
    }

    private var hasFixedGlobalProtectFields: Bool {
        id == Self.globalProtectID
            && displayName == "GlobalProtect"
            && mainProcessName == "GlobalProtect"
            && helperProcessNames == ["PanGPA"]
            && protectedProcessNames == ["PanGPS"]
            && appPath == "/Applications/GlobalProtect.app"
    }

    /// `<appPath>/Contents/MacOS/`: a main-process match must be executed from
    /// here. Trailing slash included so prefix checks cannot match a sibling
    /// bundle whose name merely starts with this one.
    var mainExecutableDirectory: String {
        URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .standardizedFileURL.path + "/"
    }

    /// `<appPath>/Contents/`: helper matches must be executed from inside the
    /// bundle, anywhere under Contents.
    var bundleContentsDirectory: String {
        URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .standardizedFileURL.path + "/"
    }

    func matchesLookupName(_ name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }

        return displayName.caseInsensitiveCompare(normalizedName) == .orderedSame
            || mainProcessName.caseInsensitiveCompare(normalizedName) == .orderedSame
    }

    static let globalProtectUserLaunchAgentJobs = [
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangpa",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist"
        ),
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangps",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangps.plist",
            isRequired: false
        )
    ]

    static let legacyGlobalProtectUserLaunchAgentJobs = [
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangpa",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist"
        )
    ]

    static let globalProtectSystemLaunchDaemonJobs = [
        SystemLaunchDaemonJob(
            label: "com.paloaltonetworks.gp.pangpsd",
            plistPath: "/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist",
            processName: "PanGPS",
            servicePort: 4767
        )
    ]
}

struct WatchedAppSnapshot: Equatable, Sendable {
    var preset: WatchedAppPreset
    /// Main, helper, and *system-daemon* protected names observed running.
    var runningNames: Set<String>
    /// PIDs of the processes that matched the main process definition. Lifecycle
    /// actions that must leave the main app alone (Quit Helpers) use these to
    /// keep a launch agent that runs the main binary loaded.
    var mainProcessPIDs: Set<Int32> = []
    /// Protected names observed running *without* root privileges. Such a
    /// process is a per-user instance (for GlobalProtect, the optional `pangps`
    /// user agent), never the protected system daemon, and it is reported
    /// separately so it is not mistaken for the daemon. It is still never
    /// signalled by name; Keep Off and Quit unload it through launchd only.
    var unprivilegedProtectedNames: Set<String> = []

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

    var unprivilegedProtectedRunning: [String] {
        preset.protectedProcessNames.filter { unprivilegedProtectedNames.contains($0) }
    }

    var hasAny: Bool {
        !runningNames.isEmpty || !unprivilegedProtectedNames.isEmpty
    }

    var detail: String {
        var names: [String] = []
        if isMainRunning {
            names.append(preset.mainProcessName)
        }
        names.append(contentsOf: helpersRunning)
        names.append(contentsOf: protectedRunning)
        names.append(contentsOf: unprivilegedProtectedRunning.map { "\($0) (user)" })
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
        if contains(where: { !$0.protectedRunning.isEmpty || !$0.unprivilegedProtectedRunning.isEmpty }) {
            return .protectedOnly
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
