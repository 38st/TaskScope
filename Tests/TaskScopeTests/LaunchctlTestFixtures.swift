func launchctlPrintOutput(pid: Int32, target: String = "gui/501/example.agent") -> String {
    "\(target) = {\n\tpid = \(pid)\n}"
}
