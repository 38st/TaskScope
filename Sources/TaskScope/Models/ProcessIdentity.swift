struct ProcessIdentity: Hashable, Codable, Sendable {
    var pid: Int32
    var startTime: String
    var command: String
    var executablePath: String?
}
