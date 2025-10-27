import XCTest
@testable import SharedInfrastructure

final class SharedInfrastructureTests: XCTestCase {
    func testProcessRegistryResolvesKnownID() {
        XCTAssertEqual(ProcessRegistry.resolve("capsule.encode"), "capsule.encode")
    }
}
