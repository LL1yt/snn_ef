import XCTest
@testable import EnergeticCore

final class FlowProjectorTests: XCTestCase {
    func testBinIndexWrap() {
        let bins = 8
        XCTAssertEqual(FlowProjector.binIndex(theta: 0, bins: bins), 0)
        XCTAssertEqual(FlowProjector.binIndex(theta: 2 * .pi - 1e-6, bins: bins), bins - 1)
        XCTAssertEqual(FlowProjector.binIndex(theta: -.pi/2, bins: bins), 6) // wrap to positive
    }
}
