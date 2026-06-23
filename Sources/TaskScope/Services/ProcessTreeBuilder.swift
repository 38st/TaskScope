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

        var childPidsByParent: [Int32: [Int32]] = [:]
        var rootPids: [Int32] = []
        for process in processes {
            let parent = ppidMap[process.pid]
            if let parentPid = parent, parentPid != 0, nodesById[parentPid] != nil {
                childPidsByParent[parentPid, default: []].append(process.pid)
            } else {
                rootPids.append(process.pid)
            }
        }

        func buildNode(_ pid: Int32) -> ProcessTreeNode? {
            guard var node = nodesById[pid] else { return nil }
            if let childPids = childPidsByParent[pid] {
                node.children = childPids.compactMap { buildNode($0) }
            }
            return node
        }

        return rootPids.compactMap { buildNode($0) }
    }
}
