import XCTest
@testable import Schrodinger

final class OutlinePitchTests: XCTestCase {
    func testIndentStepsAlongMajorScale() {
        // C5 D5 E5 F5 G5 A5 B5 C6
        XCTAssertEqual((0...7).map(OutlinePitch.depth), [72, 74, 76, 77, 79, 81, 83, 84])
        XCTAssertEqual(OutlinePitch.depth(-3), 72)
    }

    func testVerticalMovesAreChromatic() {
        XCTAssertEqual(OutlinePitch.position(0, depth: 1), 74)
        XCTAssertEqual(OutlinePitch.position(1, depth: 1), 73)
        XCTAssertEqual(OutlinePitch.position(2, depth: 1), 72)
        XCTAssertEqual(OutlinePitch.row(0), 84)
        XCTAssertEqual(OutlinePitch.row(1), 83)
        XCTAssertEqual(OutlinePitch.row(500), OutlinePitch.lowest)
    }

    func testFrequency() {
        XCTAssertEqual(OutlinePitch.frequency(69), 440, accuracy: 0.001)
        XCTAssertEqual(OutlinePitch.frequency(72), 523.251, accuracy: 0.01)
    }
}
