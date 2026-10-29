import XCTest

final class NavigationTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("files-navigation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fileManager.fileExists(atPath: root.path) {
            try? fileManager.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Path resolution

    func testTildeExpansion() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(PathResolver.expand("~", homeDirectory: home), "/Users/example")
        XCTAssertEqual(PathResolver.expand("~/Documents", homeDirectory: home), "/Users/example/Documents")
        XCTAssertEqual(PathResolver.expand("  ~/Documents/  ", homeDirectory: home), "/Users/example/Documents")
    }

    func testStandardization() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(PathResolver.expand("/tmp//a/../b/", homeDirectory: home), "/tmp/b")
        XCTAssertEqual(PathResolver.expand("relative/path"), "relative/path")
    }

    func testDirectoryResolution() throws {
        let folder = root.appendingPathComponent("Folder With Spaces", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = try PathResolver.directoryURL(from: "  \(folder.path)/  ")
        XCTAssertEqual(resolved.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testUnicodeDirectoryResolution() throws {
        let folder = root.appendingPathComponent("Ünïcode — 目录", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = try PathResolver.directoryURL(from: folder.path)
        XCTAssertEqual(resolved.lastPathComponent, "Ünïcode — 目录")
    }

    func testMissingPathThrows() {
        let missing = root.appendingPathComponent("nope", isDirectory: true).path
        XCTAssertThrowsError(try PathResolver.directoryURL(from: missing)) { error in
            XCTAssertEqual(error as? PathError, .notFound(missing))
        }
    }

    func testFileIsNotADirectory() throws {
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try PathResolver.directoryURL(from: file.path)) { error in
            XCTAssertEqual(error as? PathError, .notDirectory(file.path))
        }
    }

    func testRelativePathIsRejected() {
        XCTAssertThrowsError(try PathResolver.directoryURL(from: "Documents")) { error in
            XCTAssertEqual(error as? PathError, .notAbsolute("Documents"))
        }
    }

    func testEmptyPathIsRejected() {
        XCTAssertThrowsError(try PathResolver.directoryURL(from: "   ")) { error in
            XCTAssertEqual(error as? PathError, .empty)
        }
    }

    // MARK: - History

    func testInitialHistoryState() {
        let history = NavigationHistory(initialURL: URL(fileURLWithPath: "/Users"))
        XCTAssertEqual(history.current.path, "/Users")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBackAndForward() {
        var history = NavigationHistory(initialURL: URL(fileURLWithPath: "/"))
        XCTAssertTrue(history.navigate(to: URL(fileURLWithPath: "/Users")))
        XCTAssertTrue(history.navigate(to: URL(fileURLWithPath: "/Users/example")))
        XCTAssertEqual(history.current.path, "/Users/example")
        XCTAssertTrue(history.canGoBack)

        XCTAssertEqual(history.goBack()?.path, "/Users")
        XCTAssertEqual(history.goBack()?.path, "/")
        XCTAssertNil(history.goBack())
        XCTAssertTrue(history.canGoForward)

        XCTAssertEqual(history.goForward()?.path, "/Users")
        XCTAssertEqual(history.goForward()?.path, "/Users/example")
        XCTAssertNil(history.goForward())
    }

    func testDuplicateNavigationIsNotRecorded() {
        var history = NavigationHistory(initialURL: URL(fileURLWithPath: "/Users"))
        XCTAssertFalse(history.navigate(to: URL(fileURLWithPath: "/Users/")))
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testNavigatingAfterBackDiscardsForwardHistory() {
        var history = NavigationHistory(initialURL: URL(fileURLWithPath: "/"))
        history.navigate(to: URL(fileURLWithPath: "/Users"))
        history.navigate(to: URL(fileURLWithPath: "/Users/example"))
        _ = history.goBack()
        XCTAssertTrue(history.canGoForward)
        XCTAssertTrue(history.navigate(to: URL(fileURLWithPath: "/Applications")))
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.current.path, "/Applications")
    }

    func testReplaceCurrentDoesNotAddHistory() {
        var history = NavigationHistory(initialURL: URL(fileURLWithPath: "/Users"))
        history.replaceCurrent(with: URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(history.current.path, "/Applications")
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testIndependentHistories() {
        var first = NavigationHistory(initialURL: URL(fileURLWithPath: "/Users"))
        var second = NavigationHistory(initialURL: URL(fileURLWithPath: "/Applications"))

        first.navigate(to: URL(fileURLWithPath: "/Users/example"))
        second.navigate(to: URL(fileURLWithPath: "/Applications/Utilities"))

        XCTAssertEqual(first.current.path, "/Users/example")
        XCTAssertEqual(second.current.path, "/Applications/Utilities")
        _ = first.goBack()
        XCTAssertEqual(first.current.path, "/Users")
        XCTAssertEqual(second.current.path, "/Applications/Utilities")
        XCTAssertEqual(second.entries.count, 2)
    }

    // MARK: - Directory listing

    func testHiddenFilesAreExcludedUnlessRequested() throws {
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("visible.txt"))

        let hiddenExcluded = try DirectoryListing.items(in: root, includeHidden: false)
        XCTAssertEqual(Set(hiddenExcluded.map { $0.name }), ["visible.txt"])

        let hiddenIncluded = try DirectoryListing.items(in: root, includeHidden: true)
        XCTAssertEqual(Set(hiddenIncluded.map { $0.name }), ["visible.txt", ".hidden"])
    }

    func testSortingFoldersFirstAndNaturalNames() throws {
        for name in ["b.txt", "a.txt", "file10.txt", "file2.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try fileManager.createDirectory(at: root.appendingPathComponent("Zeta", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("alpha", isDirectory: true), withIntermediateDirectories: true)

        let items = try DirectoryListing.items(in: root, includeHidden: false)
        let ascending = DirectoryListing.sort(items, by: .name, ascending: true).map { $0.name }
        XCTAssertEqual(ascending, ["alpha", "Zeta", "a.txt", "b.txt", "file2.txt", "file10.txt"])

        let descending = DirectoryListing.sort(items, by: .name, ascending: false).map { $0.name }
        XCTAssertEqual(descending, ["Zeta", "alpha", "file10.txt", "file2.txt", "b.txt", "a.txt"])
    }

    func testSortingBySizePutsFoldersFirst() throws {
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("small.bin"))
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("large.bin"))
        try fileManager.createDirectory(at: root.appendingPathComponent("Folder", isDirectory: true), withIntermediateDirectories: true)

        let items = try DirectoryListing.items(in: root, includeHidden: false)
        let ascending = DirectoryListing.sort(items, by: .size, ascending: true).map { $0.name }
        XCTAssertEqual(ascending, ["Folder", "small.bin", "large.bin"])
        let descending = DirectoryListing.sort(items, by: .size, ascending: false).map { $0.name }
        XCTAssertEqual(descending, ["Folder", "large.bin", "small.bin"])
    }

    func testPackageIsListedAsDocumentAndSortsWithFiles() throws {
        let bundle = root.appendingPathComponent("Probe.app", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Folder", isDirectory: true), withIntermediateDirectories: true)

        let item = FileSystemItem(url: bundle)
        XCTAssertTrue(item.isPackage)
        XCTAssertFalse(item.isDirectory, "Packages are directories on disk but behave as documents")

        let items = try DirectoryListing.items(in: root, includeHidden: false)
        let sorted = DirectoryListing.sort(items, by: .name, ascending: true).map { $0.name }
        XCTAssertEqual(sorted, ["Folder", "Probe.app"])
    }

    func testFileSystemItemUsesMetadataKind() throws {
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = FileSystemItem(url: folder)
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.name, "Folder")
        XCTAssertFalse(item.kind.isEmpty)
    }
}
