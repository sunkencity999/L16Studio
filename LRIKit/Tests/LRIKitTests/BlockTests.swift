import XCTest
@testable import LRIKit

final class BlockTests: XCTestCase {
    func testMagicRejection() {
        let bad = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try LRIBlock.parse(from: bad))
    }
}
