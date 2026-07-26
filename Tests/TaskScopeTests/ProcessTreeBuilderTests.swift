import XCTest
@testable import TaskScope

@MainActor
final class ProcessTreeBuilderTests: XCTestCase {
    func testBuildNestsChildrenUnderVisibleParents() {
        let root = process(pid: 100, command: "/Applications/Root.app/Root")
        let child = process(pid: 101, command: "/usr/bin/child")
        let grandchild = process(pid: 102, command: "/usr/bin/grandchild")
        let orphan = process(pid: 200, command: "/usr/bin/orphan")

        let tree = ProcessTreeBuilder.build(
            from: [root, child, grandchild, orphan],
            ppidMap: [
                100: 1,
                101: 100,
                102: 101,
                200: 999
            ]
        )

        XCTAssertEqual(tree.map(\.id), [100, 200])
        XCTAssertEqual(tree[0].children.map(\.id), [101])
        XCTAssertEqual(tree[0].children[0].children.map(\.id), [102])
        XCTAssertEqual(tree[1].children, [])
    }

    func testFilteredTreePreservesAvailableAncestors() {
        let root = process(pid: 100, command: "root")
        let child = process(pid: 101, command: "child")
        let match = process(pid: 102, command: "match")

        let tree = ProcessTreeBuilder.build(
            from: [root, child, match],
            ppidMap: [100: 1, 101: 100, 102: 101],
            matchingPIDs: [102]
        )

        XCTAssertEqual(tree.map(\.id), [100])
        XCTAssertEqual(tree[0].children.map(\.id), [101])
        XCTAssertEqual(tree[0].children[0].children.map(\.id), [102])
    }

    func testSelfParentAndCyclesProduceFiniteDeterministicRoots() {
        let selfParent = process(pid: 10, command: "self")
        let first = process(pid: 20, command: "first")
        let second = process(pid: 21, command: "second")

        let tree = ProcessTreeBuilder.build(
            from: [selfParent, first, second],
            ppidMap: [10: 10, 20: 21, 21: 20]
        )

        XCTAssertEqual(tree.map(\.id), [10, 20])
        XCTAssertEqual(tree[1].children.map(\.id), [21])
    }

    private func process(pid: Int32, command: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 0,
            cpu: 0,
            memoryMB: 0,
            command: command,
            elapsedTime: "",
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }
}
