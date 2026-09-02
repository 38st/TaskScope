import Darwin

struct ShellCommandResult: Equatable, Sendable {
    var command: String
    var stdout: String
    var stderr: String
    var exitCode: Int32
    /// The signal that terminated the child when it did not exit normally.
    /// `exitCode` then carries the signal number for backward compatibility.
    var terminatedBySignal: Int32? = nil

    var succeeded: Bool {
        exitCode == 0 && terminatedBySignal == nil
    }

    /// "terminated by SIGTERM" or "exited with status 15", for messages that
    /// used to conflate the two.
    var failureDescription: String {
        if let signal = terminatedBySignal {
            return "terminated by \(Self.signalName(signal))"
        }
        return "exited with status \(exitCode)"
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGABRT: "SIGABRT"
        case SIGKILL: "SIGKILL"
        case SIGSEGV: "SIGSEGV"
        case SIGPIPE: "SIGPIPE"
        case SIGALRM: "SIGALRM"
        case SIGTERM: "SIGTERM"
        default: "signal \(signal)"
        }
    }
}
