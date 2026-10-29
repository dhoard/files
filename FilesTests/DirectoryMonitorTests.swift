import XCTest

final class DirectoryMonitorTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("files-monitor-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testReportsChangesInWatchedDirectory() {
        let monitor = DirectoryMonitor()
        let changed = expectation(description: "directory change reported")
        var fulfilled = false

        monitor.onChange = { paths in
            guard !fulfilled else { return }
            // FSEvents may report the real (/private/var/...) path for
            // temporary directories, so compare with filesystem identity.
            if paths.contains(where: {
                VolumeInfo.isSameOrDescendant(URL(fileURLWithPath: $0), of: self.directory)
            }) {
                fulfilled = true
                changed.fulfill()
            }
        }
        monitor.setWatchedPaths([directory.path])
        defer { monitor.stop() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            try? Data("changed".utf8).write(to: self.directory.appendingPathComponent("new-file.txt"))
        }

        wait(for: [changed], timeout: 10)
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("new-file.txt").path))
    }

    func testEmptyPathSetStopsCleanly() {
        let monitor = DirectoryMonitor()
        monitor.setWatchedPaths([])
        monitor.setWatchedPaths([directory.path])
        monitor.setWatchedPaths([directory.path])
        monitor.stop()
        monitor.stop()
    }
}
