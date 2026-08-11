enum TaskScopeSection: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case presets = "Presets"

    var id: String {
        rawValue
    }
}
