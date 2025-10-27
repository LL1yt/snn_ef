import XCTest
@testable import CapsuleCore

final class CapsuleCoreTests: XCTestCase {
    func testPlaceholderDescription() {
        XCTAssertEqual(CapsulePlaceholder().describe(), "CapsuleCore placeholder")
    }
}
