import Foundation

struct ProcessTreeNode: Identifiable, Equatable {
    var process: AppProcess
    var children: [ProcessTreeNode]
    var id: Int32 { process.pid }
}

@MainActor
final class ProcessTreeBuilder {
    static func build(from processes: [AppProcess], ppidMap: [Int32: Int32]) -> [ProcessTreeNode] {
        var nodesById: [Int32: ProcessTreeNode] = [:]
        for process in processes {
            nodesById[process.pid] = ProcessTreeNode(process: process, children: [])
        }

        var roots: [ProcessTreeNode] = []
        for process in processes {
            guard var node = nodesById[process.pid] else { continue }
            let parent = ppidMap[process.pid]
            if let parentPid = parent, parentPid != 0, var parentNode = nodesById[parentPid] {
                parentNode.children.append(node)
                nodesById[parentPid] = parentNode
            } else {
                roots.append(node)
            }
        }
        return roots
    }
}
