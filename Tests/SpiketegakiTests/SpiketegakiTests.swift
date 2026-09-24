import XCTest
@testable import Spiketegaki

final class SpiketegakiTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(Spiketegaki.version, "0.1.0")
    }
}
