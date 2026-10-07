/// Identifies a process using its PID, UTC start time, and resolved executable
/// path. Paths can change during a lifetime, but remain part of equality to
/// reject executable changes and strengthen second-resolution start evidence.
/// `command` is argv-backed, and processes such as postgres
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
