import XCTest
import Spiketegaki
@testable import SpiketegakiTraining

final class SpiketegakiTrainingTests: XCTestCase {
    func testVersionMatchesInferenceLibrary() {
        XCTAssertEqual(SpiketegakiTraining.version, Spiketegaki.version)
    }
}
