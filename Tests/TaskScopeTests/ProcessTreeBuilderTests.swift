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
