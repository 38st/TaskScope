import XCTest
@testable import TaskScope

final class LifecycleModelsTests: XCTestCase {
    func testJobStateDisplayNamesSeparateWords() {
        XCTAssertEqual(LifecycleJobState.missing.displayName, "Missing")
        XCTAssertEqual(LifecycleJobState.alreadyLoaded.displayName, "Already loaded")
        XCTAssertEqual(LifecycleJobState.alreadyUnloaded.displayName, "Already unloaded")
        XCTAssertEqual(LifecycleJobState.changed.displayName, "Changed")
        XCTAssertEqual(LifecycleJobState.failed.displayName, "Failed")
        XCTAssertEqual(LifecycleJobState.verified.displayName, "Verified")
    }
}
