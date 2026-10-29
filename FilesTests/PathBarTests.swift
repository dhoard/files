import AppKit
import XCTest

final class PathBarTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("files-pathbar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("alpine"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("Beta"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("alpha.txt"))
    }

    override func tearDownWithError() throws {
        if let directory, fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testSingleFolderCompletionAddsSlash() throws {
        let pathBar = PathBarController()
        pathBar.setCurrentPath(directory.path)
        XCTAssertEqual(pathBar.textField.stringValue, directory.path)
        XCTAssertEqual(pathBar.completion(for: directory.path + "/Be"), directory.path + "/Beta/")
    }

    func testSingleFileCompletionDoesNotAddSlash() {
        let pathBar = PathBarController()
        XCTAssertEqual(pathBar.completion(for: directory.path + "/alpha.t"), directory.path + "/alpha.txt")
    }

    func testMultipleMatchesExtendToCommonPrefix() {
        let pathBar = PathBarController()
        XCTAssertEqual(pathBar.completion(for: directory.path + "/al"), directory.path + "/alp")
    }

    func testNoCompletionForUnchangedPrefixOrUnknownName() {
        let pathBar = PathBarController()
        XCTAssertNil(pathBar.completion(for: directory.path + "/alpha"))
        XCTAssertNil(pathBar.completion(for: directory.path + "/zzz"))
        XCTAssertNil(pathBar.completion(for: "relative/path"))
    }
}
