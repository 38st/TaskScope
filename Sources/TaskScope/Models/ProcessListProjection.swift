import Foundation

/// Read-only inventory with derived lists cached for its lifetime. Replacing the
/// projection replaces every cache together, so no list can outlive its inventory.
struct ProcessListProjection {
    let inventory: [AppProcess]

    private struct DisplayListKey: Hashable {
        var query: ProcessListQuery
        var limit: Int
        var sortKey: ProcessSortKey
    }

    private var sortedInventoryCache: (sortKey: ProcessSortKey, processes: [AppProcess])?
    private var displayListCache: [DisplayListKey: DisplayList] = [:]
    private var treeRootsCache: [DisplayListKey: [ProcessTreeNode]] = [:]

    init(inventory: [AppProcess] = []) {
        self.inventory = inventory
    }

    var ppidMap: [Int32: Int32] {
        Dictionary(inventory.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { _, last in last })
    }

    mutating func displayProcesses(
        sortKey: ProcessSortKey,
        limit: Int,
        matching predicate: (AppProcess) -> Bool = { _ in true }
    ) -> [AppProcess] {
        Array(sortedInventory(by: sortKey).lazy.filter(predicate).prefix(max(0, limit)))
    }

    mutating func displayProcesses(
        for query: ProcessListQuery,
        sortKey: ProcessSortKey,
        limit: Int
    ) -> [AppProcess] {
        displayList(for: query, sortKey: sortKey, limit: limit).processes
    }

    struct DisplayList {
        var processes: [AppProcess]
        var matchCount: Int
    }

    mutating func displayList(
        for query: ProcessListQuery,
        sortKey: ProcessSortKey,
        limit: Int
    ) -> DisplayList {
        let key = DisplayListKey(query: query, limit: limit, sortKey: sortKey)
        if let cached = displayListCache[key] {
            return cached
        }
        let matches = sortedInventory(by: sortKey).filter(query.matches)
        let result = DisplayList(processes: Array(matches.prefix(max(0, limit))), matchCount: matches.count)
        displayListCache[key] = result
        return result
    }

    mutating func treeRoots(
        for query: ProcessListQuery,
        sortKey: ProcessSortKey,
        limit: Int
    ) -> [ProcessTreeNode] {
        let key = DisplayListKey(query: query, limit: limit, sortKey: sortKey)
        if let cached = treeRootsCache[key] {
            return cached
        }
        let matches = displayProcesses(for: query, sortKey: sortKey, limit: limit)
        let roots = ProcessTreeBuilder.build(
            from: inventory,
            ppidMap: ppidMap,
            matchingPIDs: Set(matches.map(\.pid))
        )
        treeRootsCache[key] = roots
        return roots
    }

    private mutating func sortedInventory(by sortKey: ProcessSortKey) -> [AppProcess] {
        if let cached = sortedInventoryCache, cached.sortKey == sortKey {
            return cached.processes
        }
        let processes = inventory.sorted { lhs, rhs in
            switch sortKey {
            case .cpu:
                if lhs.cpu == rhs.cpu {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.cpu > rhs.cpu
            case .memory:
                if lhs.memoryMB == rhs.memoryMB {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.memoryMB > rhs.memoryMB
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return comparison == .orderedSame ? lhs.pid < rhs.pid : comparison == .orderedAscending
            case .pid:
                return lhs.pid < rhs.pid
            }
        }
        sortedInventoryCache = (sortKey, processes)
        return processes
    }
}
