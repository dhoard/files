import Foundation
import XCTest

final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "files-preferences-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testDefaults() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.showHiddenFiles)
        XCTAssertNil(preferences.sortKey)
        XCTAssertTrue(preferences.sortAscending)
        XCTAssertNil(preferences.splitFraction)
        XCTAssertNil(preferences.windowFrame)
        XCTAssertNil(preferences.columnWidth(for: "name"))
    }

    func testRoundTrips() {
        let preferences = Preferences(defaults: defaults)
        preferences.showHiddenFiles = true
        preferences.sortKey = "size"
        preferences.sortAscending = false
        preferences.setColumnWidth(321, for: "size")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.showHiddenFiles)
        XCTAssertEqual(reloaded.sortKey, "size")
        XCTAssertFalse(reloaded.sortAscending)
        XCTAssertEqual(reloaded.columnWidth(for: "size"), 321)
    }

    func testSplitFractionIsClamped() {
        let preferences = Preferences(defaults: defaults)
        preferences.splitFraction = 0.95
        XCTAssertEqual(try XCTUnwrap(preferences.splitFraction), 0.75, accuracy: 0.0001)
        preferences.splitFraction = 0.01
        XCTAssertEqual(try XCTUnwrap(preferences.splitFraction), 0.15, accuracy: 0.0001)
        preferences.splitFraction = 0.4
        XCTAssertEqual(try XCTUnwrap(preferences.splitFraction), 0.4, accuracy: 0.0001)
    }

    func testWindowFrameRoundTrip() throws {
        let preferences = Preferences(defaults: defaults)
        let frame = NSRect(x: 100, y: 120, width: 900, height: 640)
        preferences.windowFrame = frame
        let restored = try XCTUnwrap(preferences.windowFrame)
        XCTAssertEqual(restored.origin.x, frame.origin.x, accuracy: 0.5)
        XCTAssertEqual(restored.origin.y, frame.origin.y, accuracy: 0.5)
        XCTAssertEqual(restored.size.width, frame.size.width, accuracy: 0.5)
        XCTAssertEqual(restored.size.height, frame.size.height, accuracy: 0.5)
    }

    func testDegenerateWindowFrameIsIgnored() {
        let preferences = Preferences(defaults: defaults)
        defaults.set(NSStringFromRect(NSRect(x: 0, y: 0, width: 10, height: 10)), forKey: PreferenceKey.windowFrame)
        XCTAssertNil(preferences.windowFrame)
    }
}
