/// Identifies one process lifetime. Equality uses only what the kernel keeps
/// stable for that lifetime: the PID, its start time, and the resolved
/// executable path. `command` is argv-backed, and processes such as postgres
/// backends or sshd sessions rewrite it while running, so it is carried for
/// display only and never decides whether two observations are the same process.
struct ProcessIdentity: Hashable, Codable, Sendable {
    var pid: Int32
    var startTime: String
    var command: String
    var executablePath: String?

    static func == (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        lhs.pid == rhs.pid
            && lhs.startTime == rhs.startTime
            && lhs.executablePath == rhs.executablePath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(startTime)
        hasher.combine(executablePath)
    }
}
