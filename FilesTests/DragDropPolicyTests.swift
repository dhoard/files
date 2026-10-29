import AppKit
import XCTest

final class DragDropPolicyTests: XCTestCase {
    func testSameVolumeDefaultsToMove() {
        let operation = DragDropCoordinator.desiredOperation(
            modifierFlags: [],
            sameVolume: true,
            allowed: [.copy, .move]
        )
        XCTAssertEqual(operation, .move)
    }

    func testCrossVolumeDefaultsToCopy() {
        let operation = DragDropCoordinator.desiredOperation(
            modifierFlags: [],
            sameVolume: false,
            allowed: [.copy, .move]
        )
        XCTAssertEqual(operation, .copy)
    }

    func testOptionForcesCopy() {
        let operation = DragDropCoordinator.desiredOperation(
            modifierFlags: [.option],
            sameVolume: true,
            allowed: [.copy, .move]
        )
        XCTAssertEqual(operation, .copy)
    }

    func testCommandForcesMove() {
        let operation = DragDropCoordinator.desiredOperation(
            modifierFlags: [.command],
            sameVolume: false,
            allowed: [.copy, .move]
        )
        XCTAssertEqual(operation, .move)
    }

    func testSourceMaskIsRespected() {
        let copyOnly = DragDropCoordinator.desiredOperation(
            modifierFlags: [],
            sameVolume: true,
            allowed: [.copy]
        )
        XCTAssertEqual(copyOnly, .copy, "A source that only offers copy must not be moved")

        let moveOnly = DragDropCoordinator.desiredOperation(
            modifierFlags: [.option],
            sameVolume: false,
            allowed: [.move]
        )
        XCTAssertEqual(moveOnly, .move, "A source that only offers move must not be copied")

        let nothing = DragDropCoordinator.desiredOperation(
            modifierFlags: [],
            sameVolume: true,
            allowed: []
        )
        XCTAssertEqual(nothing, [])
    }

    func testGenericSourceMaskPermitsBoth() {
        XCTAssertEqual(
            DragDropCoordinator.desiredOperation(modifierFlags: [], sameVolume: false, allowed: .generic),
            .copy
        )
        XCTAssertEqual(
            DragDropCoordinator.desiredOperation(modifierFlags: [], sameVolume: true, allowed: .generic),
            .move
        )
    }
}
