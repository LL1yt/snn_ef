import XCTest
@testable import EnergeticCore

final class EnergeticCoreTests: XCTestCase {
    func testPlaceholderDescription() {
        XCTAssertEqual(EnergeticRouterPlaceholder().describe(), "EnergeticRouter placeholder")
    }
}
