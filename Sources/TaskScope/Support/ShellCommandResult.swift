struct ShellCommandResult: Equatable, Sendable {
    var command: String
    var stdout: String
    var stderr: String
    var exitCode: Int32

    var succeeded: Bool {
        exitCode == 0
    }
}
