import XCTest

final class FileOperationsTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let operations = FileOperations()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("files-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fileManager.fileExists(atPath: root.path) {
            try? fileManager.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ relativePath: String, contents: String = "hello") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: url.path, contents: Data(contents.utf8)))
        return url
    }

    private func handler(_ choices: [ConflictResolution]) -> FileOperations.ConflictHandler {
        var remaining = choices
        return { _ in
            guard !remaining.isEmpty else { return .cancel }
            return remaining.removeFirst()
        }
    }

    private func neverReplace() -> FileOperations.ConflictHandler {
        { _ in
            XCTFail("Unexpected conflict prompt")
            return .cancel
        }
    }

    private func contents(of directory: URL) -> Set<String> {
        Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    // MARK: - Copy

    func testCopySingleFile() throws {
        let source = try makeFile("source.txt", contents: "copy me")
        let destination = try makeDirectory("destination")

        let result = operations.copy(
            items: [source],
            to: destination,
            conflictHandler: neverReplace()
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.completed.count, 1)
        let copied = destination.appendingPathComponent("source.txt")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "copy me")
        XCTAssertTrue(fileManager.fileExists(atPath: source.path), "Copy must not remove the source")
    }

    func testCopyMultipleFiles() throws {
        let first = try makeFile("one.txt", contents: "1")
        let second = try makeFile("two.txt", contents: "2")
        let third = try makeFile("three.txt", contents: "3")
        let destination = try makeDirectory("destination")

        let result = operations.copy(
            items: [first, second, third],
            to: destination,
            conflictHandler: neverReplace()
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(contents(of: destination), ["one.txt", "two.txt", "three.txt"])
    }

    func testCopyNestedDirectory() throws {
        let folder = try makeDirectory("Alpha")
        try makeFile("Alpha/root.txt", contents: "root")
        try makeFile("Alpha/nested/deep.txt", contents: "deep")
        _ = try makeDirectory("Alpha/empty")
        let destination = try makeDirectory("destination")

        let result = operations.copy(
            items: [folder],
            to: destination,
            conflictHandler: neverReplace()
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        let copied = destination.appendingPathComponent("Alpha")
        XCTAssertEqual(contents(of: copied), ["root.txt", "nested", "empty"])
        XCTAssertEqual(
            try String(contentsOf: copied.appendingPathComponent("nested/deep.txt"), encoding: .utf8),
            "deep"
        )
    }

    func testCopyUnicodeAndSpaces() throws {
        let source = try makeFile("Ünïcode file — spaces.txt", contents: "unicode")
        let destination = try makeDirectory("Ziel Ordner")
        let result = operations.copy(items: [source], to: destination, conflictHandler: neverReplace())

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        let copied = destination.appendingPathComponent("Ünïcode file — spaces.txt")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "unicode")
    }

    func testCopyHiddenFile() throws {
        let source = try makeFile(".hidden-file", contents: "hidden")
        let destination = try makeDirectory("destination")
        let result = operations.copy(items: [source], to: destination, conflictHandler: neverReplace())

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent(".hidden-file").path))
    }

    func testCopySymbolicLinkDoesNotFollowOrLoop() throws {
        let folder = try makeDirectory("LinkHost")
        try makeFile("LinkHost/file.txt", contents: "x")
        try fileManager.createSymbolicLink(
            atPath: folder.appendingPathComponent("loop").path,
            withDestinationPath: folder.path
        )
        let destination = try makeDirectory("destination")

        let result = operations.copy(items: [folder], to: destination, conflictHandler: neverReplace())

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        let copiedLink = destination.appendingPathComponent("LinkHost/loop")
        let target = try fileManager.destinationOfSymbolicLink(atPath: copiedLink.path)
        XCTAssertEqual(target, folder.path, "Symbolic links are copied as links, not followed")
    }

    func testCopyDanglingSymbolicLink() throws {
        let linkPath = root.appendingPathComponent("dangling")
        try fileManager.createSymbolicLink(atPath: linkPath.path, withDestinationPath: "/nonexistent/target")
        let destination = try makeDirectory("destination")

        let result = operations.copy(items: [linkPath], to: destination, conflictHandler: neverReplace())

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling").path),
            "/nonexistent/target"
        )
    }

    // MARK: - Move / rename

    func testMoveFile() throws {
        let source = try makeFile("move-me.txt", contents: "moved")
        let destination = try makeDirectory("destination")

        let result = operations.move(items: [source], to: destination, conflictHandler: neverReplace())

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("move-me.txt"), encoding: .utf8),
            "moved"
        )
    }

    func testMoveDirectory() throws {
        let folder = try makeDirectory("MoveMe")
        try makeFile("MoveMe/child.txt")
        let destination = try makeDirectory("destination")

        let result = operations.move(items: [folder], to: destination, conflictHandler: neverReplace())

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertFalse(fileManager.fileExists(atPath: folder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("MoveMe/child.txt").path))
    }

    func testRenameFile() throws {
        let source = try makeFile("old name.txt", contents: "renamed")
        let renamed = try operations.rename(source, to: "new name.txt")

        XCTAssertEqual(renamed.lastPathComponent, "new name.txt")
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "renamed")
    }

    func testCaseOnlyRename() throws {
        let source = try makeFile("Case.txt", contents: "case")
        let renamed = try operations.rename(source, to: "CASE.txt")

        XCTAssertEqual(renamed.lastPathComponent, "CASE.txt")
        XCTAssertEqual(contents(of: root), ["CASE.txt"])
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "case")
    }

    func testRenameRejectsInvalidNames() throws {
        let source = try makeFile("valid.txt")
        XCTAssertThrowsError(try operations.rename(source, to: ""))
        XCTAssertThrowsError(try operations.rename(source, to: "a/b"))
        XCTAssertThrowsError(try operations.rename(source, to: ":"))
        XCTAssertThrowsError(try operations.rename(source, to: "   "))
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }

    func testRenameCollisionThrows() throws {
        let source = try makeFile("first.txt")
        try makeFile("second.txt")
        XCTAssertThrowsError(try operations.rename(source, to: "second.txt"))
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("second.txt").path))
    }

    func testCreateFolderUsesUniqueNames() throws {
        let first = try operations.createFolder(in: root)
        XCTAssertEqual(first.lastPathComponent, "untitled folder")
        XCTAssertTrue(fileManager.fileExists(atPath: first.path))

        let second = try operations.createFolder(in: root)
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
        XCTAssertTrue(fileManager.fileExists(atPath: second.path))

        let custom = try operations.createFolder(in: root, preferredName: "untitled folder")
        XCTAssertEqual(custom.lastPathComponent, "untitled folder 3")
    }

    // MARK: - Conflicts

    func testConflictSkipLeavesDestinationUntouched() throws {
        let source = try makeFile("source.txt", contents: "new")
        let destination = try makeDirectory("destination")
        let existing = try makeFile("destination/source.txt", contents: "old")

        let result = operations.copy(
            items: [source],
            to: destination,
            conflictHandler: handler([.skip])
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
    }

    func testConflictReplaceOverwrites() throws {
        let source = try makeFile("source.txt", contents: "new")
        let destination = try makeDirectory("destination")
        try makeFile("destination/source.txt", contents: "old")

        let result = operations.copy(
            items: [source],
            to: destination,
            conflictHandler: handler([.replace])
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.completed.count, 1)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8),
            "new"
        )
        // Replacement staging must not leave temp files behind.
        XCTAssertEqual(contents(of: destination), ["source.txt"])
    }

    func testConflictCancelStopsOperation() throws {
        let source = try makeFile("source.txt", contents: "new")
        let second = try makeFile("second.txt", contents: "second")
        let destination = try makeDirectory("destination")
        try makeFile("destination/source.txt", contents: "old")

        let result = operations.copy(
            items: [source, second],
            to: destination,
            conflictHandler: handler([.cancel])
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8), "old")
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("second.txt").path))
    }

    func testMoveReplaceKeepsExactlyOneDestination() throws {
        let source = try makeFile("source.txt", contents: "new")
        let destination = try makeDirectory("destination")
        try makeFile("destination/source.txt", contents: "old")

        let result = operations.move(
            items: [source],
            to: destination,
            conflictHandler: handler([.replace])
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        XCTAssertEqual(contents(of: destination), ["source.txt"])
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8),
            "new"
        )
    }

    // MARK: - Safety validation

    func testSelfCopyIsRejected() throws {
        let source = try makeFile("self.txt")
        XCTAssertThrowsError(try operations.validate(items: [source], to: root))

        let result = operations.copy(items: [source], to: root, conflictHandler: neverReplace())
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }

    func testCopyIntoOwnDescendantIsRejected() throws {
        let folder = try makeDirectory("Parent")
        let child = try makeDirectory("Parent/Child")
        let source = try makeFile("Parent/file.txt")

        XCTAssertThrowsError(try operations.validate(items: [folder], to: child))
        XCTAssertThrowsError(try operations.validate(items: [source], to: folder))
        XCTAssertFalse(fileManager.fileExists(atPath: child.appendingPathComponent("Parent").path))
    }

    func testMoveIntoOwnDescendantIsRejected() throws {
        let folder = try makeDirectory("Parent")
        let child = try makeDirectory("Parent/Child")

        let result = operations.move(items: [folder], to: child, conflictHandler: neverReplace())

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: child.path))
    }

    func testCopyIntoMissingDestinationFailsWithoutLosingSource() throws {
        let source = try makeFile("source.txt")
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)

        let result = operations.copy(items: [source], to: missing, conflictHandler: neverReplace())

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }

    func testMissingSourceIsReportedAndOtherItemsContinue() throws {
        let good = try makeFile("good.txt", contents: "ok")
        let missing = root.appendingPathComponent("missing.txt")
        let destination = try makeDirectory("destination")

        let result = operations.copy(
            items: [missing, good],
            to: destination,
            conflictHandler: neverReplace()
        )

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.url, missing)
        XCTAssertEqual(result.completed.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("good.txt").path))
    }

    func testCancellationStopsLongCopy() throws {
        let files = try (1...4).map { try makeFile("file-\($0).txt", contents: "\($0)") }
        let destination = try makeDirectory("destination")
        var checks = 0

        let result = operations.copy(
            items: files,
            to: destination,
            conflictHandler: neverReplace(),
            isCancelled: {
                checks += 1
                return checks > 2
            }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(result.completed.count, files.count)
        XCTAssertLessThanOrEqual(contents(of: destination).count, 2)
    }

    func testDropValidationRejectsSameFolderAndDescendants() throws {
        let folder = try makeDirectory("Folder")
        let child = try makeDirectory("Folder/Child")
        let file = try makeFile("Folder/file.txt")

        if let error = operations.dropValidationError(items: [file], destination: folder) {
            switch error {
            case .sameLocation:
                break
            default:
                XCTFail("Expected sameLocation, got \(error)")
            }
        } else {
            XCTFail("Expected a same-folder drop to be rejected")
        }
        if let error = operations.dropValidationError(items: [folder], destination: child) {
            switch error {
            case .insideItself:
                break
            default:
                XCTFail("Expected insideItself, got \(error)")
            }
        } else {
            XCTFail("Expected the drop into a descendant to be rejected")
        }
        XCTAssertNil(operations.dropValidationError(items: [file], destination: try makeDirectory("Elsewhere")))
    }

    // MARK: - Trash

    func testMoveToTrashRemovesItemFromOriginalLocation() throws {
        let source = try makeFile("trash-me-\(UUID().uuidString).txt", contents: "trash")
        let result = operations.moveToTrash([source])

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.completed.count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
    }
}
