import AppKit
import XCTest

/// Smoke tests for the per-window controller. These create real AppKit
/// windows in the test process (no UI interaction) to verify navigation,
/// history and independent per-window state.
final class ExplorerWindowSmokeTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private var controllers: [ExplorerWindowController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        root = fileManager.temporaryDirectory
            .appendingPathComponent("files-smoke-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.close()
        }
        controllers.removeAll()
        if let root, fileManager.fileExists(atPath: root.path) {
            try? fileManager.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeController(start: URL, cascadeIndex: Int = 0) -> ExplorerWindowController {
        let controller = ExplorerWindowController(startURL: start, cascadeIndex: cascadeIndex)
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    private func makeFolder(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWindowCreationAndNavigationHistory() throws {
        let start = try makeFolder("Start", under: root)
        let first = try makeFolder("First", under: start)
        let second = try makeFolder("Second", under: start)
        let controller = makeController(start: start)

        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.currentDirectory.path, start.path)

        XCTAssertTrue(controller.navigate(to: first))
        XCTAssertEqual(controller.currentDirectory.path, first.path)
        XCTAssertTrue(controller.navigate(to: second))
        XCTAssertEqual(controller.currentDirectory.path, second.path)
        controller.goBack(nil)
        XCTAssertEqual(controller.currentDirectory.path, first.path)
        controller.goBack(nil)
        XCTAssertEqual(controller.currentDirectory.path, start.path)
        controller.goBack(nil) // no-op at the start of history
        XCTAssertEqual(controller.currentDirectory.path, start.path)

        controller.goForward(nil)
        XCTAssertEqual(controller.currentDirectory.path, first.path)
        controller.goForward(nil)
        XCTAssertEqual(controller.currentDirectory.path, second.path)

        controller.goUp(nil)
        XCTAssertEqual(controller.currentDirectory.path, start.path)

        XCTAssertTrue(controller.window?.isVisible ?? false)
    }

    func testForwardToDeletedDirectoryKeepsHistoryPosition() throws {
        let start = try makeFolder("Start", under: root)
        let child = try makeFolder("Child", under: start)
        let controller = makeController(start: start)

        XCTAssertTrue(controller.navigate(to: child))
        // History: [Start, Child], current = Child.
        controller.goBack(nil)
        XCTAssertEqual(controller.currentDirectory.path, start.path)

        try fileManager.removeItem(at: child)
        controller.goForward(nil)
        XCTAssertEqual(controller.currentDirectory.path, start.path,
                       "A deleted forward entry must not move the window or the history index")

        // Recreate it: forward must still work because the index did not move.
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
        controller.goForward(nil)
        XCTAssertEqual(controller.currentDirectory.path, child.path)
    }

    func testInvalidNavigationKeepsCurrentDirectory() throws {
        let start = try makeFolder("Start", under: root)
        let controller = makeController(start: start)

        XCTAssertFalse(controller.navigate(to: root.appendingPathComponent("missing", isDirectory: true)))
        XCTAssertEqual(controller.currentDirectory.path, start.path)

        XCTAssertFalse(controller.navigate(to: URL(fileURLWithPath: "/definitely/not/a/real/folder")))
        XCTAssertEqual(controller.currentDirectory.path, start.path)
    }

    func testWindowsHaveIndependentState() throws {
        let firstRoot = try makeFolder("FirstRoot", under: root)
        let secondRoot = try makeFolder("SecondRoot", under: root)
        let firstChild = try makeFolder("ChildA", under: firstRoot)
        let secondChild = try makeFolder("ChildB", under: secondRoot)

        let firstWindow = makeController(start: firstRoot)
        let secondWindow = makeController(start: secondRoot, cascadeIndex: 1)

        firstWindow.navigate(to: firstChild)
        secondWindow.navigate(to: secondChild)

        XCTAssertEqual(firstWindow.currentDirectory.path, firstChild.path)
        XCTAssertEqual(secondWindow.currentDirectory.path, secondChild.path)

        firstWindow.goUp(nil)
        XCTAssertEqual(firstWindow.currentDirectory.path, firstRoot.path)
        XCTAssertEqual(secondWindow.currentDirectory.path, secondChild.path)

        // Closing one window must not affect the other.
        firstWindow.close()
        controllers.removeAll { $0 === firstWindow }
        XCTAssertEqual(secondWindow.currentDirectory.path, secondChild.path)
        XCTAssertTrue(secondWindow.window?.isVisible ?? false)
    }

    func testFileShortcutsAreDisabledWhileEditingText() throws {
        let start = try makeFolder("Start", under: root)
        try Data("content".utf8).write(to: start.appendingPathComponent("file.txt"))
        let controller = makeController(start: start)

        let located = locate(in: controller)
        let table = try XCTUnwrap(located.table)
        let pathField = try XCTUnwrap(located.pathField)
        waitUntil { table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let trashItem = NSMenuItem(
            title: "Move to Trash",
            action: #selector(ExplorerWindowController.moveSelectionToTrash(_:)),
            keyEquivalent: ""
        )
        let upItem = NSMenuItem(
            title: "Enclosing Folder",
            action: #selector(ExplorerWindowController.goUp(_:)),
            keyEquivalent: ""
        )
        let renameItem = NSMenuItem(
            title: "Rename",
            action: #selector(ExplorerWindowController.renameSelection(_:)),
            keyEquivalent: ""
        )

        XCTAssertTrue(controller.validateMenuItem(trashItem))
        XCTAssertTrue(controller.validateMenuItem(upItem))
        XCTAssertTrue(controller.validateMenuItem(renameItem))

        // Focus the location field: the field editor becomes first responder
        // and native text shortcuts must not be hijacked by file commands.
        XCTAssertTrue(controller.window?.makeFirstResponder(pathField) ?? false)
        XCTAssertTrue(controller.window?.firstResponder is NSText)
        XCTAssertFalse(controller.validateMenuItem(trashItem))
        XCTAssertFalse(controller.validateMenuItem(upItem))
        XCTAssertFalse(controller.validateMenuItem(renameItem))

        XCTAssertTrue(controller.window?.makeFirstResponder(table) ?? false)
        XCTAssertTrue(controller.validateMenuItem(trashItem))
    }

    func testToggleHiddenAndRefreshDoNotChangeDirectory() throws {
        let start = try makeFolder("Start", under: root)
        try Data().write(to: start.appendingPathComponent(".hidden"))
        let controller = makeController(start: start)

        controller.toggleHiddenFiles(nil)
        XCTAssertEqual(controller.currentDirectory.path, start.path)
        controller.toggleHiddenFiles(nil)
        controller.refresh(nil)
        XCTAssertEqual(controller.currentDirectory.path, start.path)
    }
}

// UI structure and asynchronous listing checks. These inspect the real view
// hierarchy created by the window controller (no accessibility permissions
// required).
extension ExplorerWindowSmokeTests {
    private func descendants(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        for subview in view.subviews {
            result.append(subview)
            result.append(contentsOf: descendants(of: subview))
        }
        return result
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func locate(in controller: ExplorerWindowController) -> (split: NSSplitView?, table: NSTableView?, outline: NSOutlineView?, pathField: NSTextField?) {
        guard let content = controller.window?.contentView else { return (nil, nil, nil, nil) }
        let views = descendants(of: content)
        let outline = views.compactMap { $0 as? NSOutlineView }.first
        let table = views.compactMap { $0 as? NSTableView }.first { !($0 is NSOutlineView) }
        let split = views.compactMap { $0 as? NSSplitView }.first
        let pathField = views.compactMap { $0 as? NSTextField }.first {
            $0.isEditable && $0.isBezeled && $0.stringValue.hasPrefix("/")
        }
        return (split, table, outline, pathField)
    }

    func testLayoutAndDirectoryListing() throws {
        let start = try makeFolder("Start", under: root)
        _ = try makeFolder("Child", under: start)
        try Data("a".utf8).write(to: start.appendingPathComponent("alpha.txt"))
        try Data("b".utf8).write(to: start.appendingPathComponent("beta.txt"))
        let controller = makeController(start: start)

        let located = locate(in: controller)
        XCTAssertNotNil(located.split, "Split view is missing")
        XCTAssertNotNil(located.table, "File listing table is missing")
        XCTAssertNotNil(located.outline, "Directory tree is missing")
        XCTAssertEqual(located.pathField?.stringValue, start.path, "Location bar must show the current POSIX path")

        let table = try XCTUnwrap(located.table)
        XCTAssertNotNil(table.headerView, "The detailed listing must show column headers")
        XCTAssertNotNil(table.enclosingScrollView)
        waitUntil { table.numberOfRows >= 3 }
        XCTAssertEqual(table.numberOfRows, 3, "Expected Child, alpha.txt and beta.txt")

        let split = try XCTUnwrap(located.split)
        XCTAssertGreaterThan(split.bounds.width, 0)
        let treeWidth = split.arrangedSubviews.first?.frame.width ?? 0
        let fraction = treeWidth / split.bounds.width
        XCTAssertGreaterThan(fraction, 0.15, "Tree pane should be at least 15% of the window")
        XCTAssertLessThan(fraction, 0.6, "Tree pane should not dominate the window")

        // Navigation updates the always-editable location bar.
        let child = start.appendingPathComponent("Child", isDirectory: true)
        XCTAssertTrue(controller.navigate(to: child))
        waitUntil { table.numberOfRows == 0 }
        XCTAssertEqual(located.pathField?.stringValue, child.path)

        // Hidden files appear only when the preference is enabled.
        try Data().write(to: child.appendingPathComponent(".secret"))
        controller.toggleHiddenFiles(nil)
        waitUntil { table.numberOfRows == 1 }
        XCTAssertEqual(table.numberOfRows, 1)
        controller.toggleHiddenFiles(nil)
        waitUntil { table.numberOfRows == 0 }
        XCTAssertEqual(table.numberOfRows, 0)
    }
}

// Cross-window clipboard operations. These use a private pasteboard and the
// real background operation pipeline (progress panel, completion, refresh).
extension ExplorerWindowSmokeTests {
    private func makePrivatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("files-ui-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func testCopyBetweenWindows() throws {
        let sourceDirectory = try makeFolder("Source", under: root)
        let destinationDirectory = try makeFolder("Destination", under: root)
        try Data("one".utf8).write(to: sourceDirectory.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: sourceDirectory.appendingPathComponent("two.txt"))

        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.clearContents() }

        let sourceWindow = makeController(start: sourceDirectory)
        sourceWindow.clipPasteboard = pasteboard
        let destinationWindow = makeController(start: destinationDirectory, cascadeIndex: 1)
        destinationWindow.clipPasteboard = pasteboard

        let sourceTable = try XCTUnwrap(locate(in: sourceWindow).table)
        waitUntil { sourceTable.numberOfRows == 2 }
        sourceTable.selectAll(nil)
        sourceWindow.copy(nil)

        let snapshot = try XCTUnwrap(ClipboardService.read(from: pasteboard))
        XCTAssertFalse(snapshot.isCut)
        XCTAssertEqual(Set(snapshot.urls.map { $0.lastPathComponent }), ["one.txt", "two.txt"])

        destinationWindow.paste(nil)
        let copiedOne = destinationDirectory.appendingPathComponent("one.txt")
        let copiedTwo = destinationDirectory.appendingPathComponent("two.txt")
        waitUntil { fileManager.fileExists(atPath: copiedOne.path) && fileManager.fileExists(atPath: copiedTwo.path) }
        XCTAssertTrue(fileManager.fileExists(atPath: copiedOne.path))
        XCTAssertTrue(fileManager.fileExists(atPath: copiedTwo.path))
        XCTAssertTrue(fileManager.fileExists(atPath: sourceDirectory.appendingPathComponent("one.txt").path),
                      "Copy must leave the sources in place")
    }

    func testCutPasteBetweenWindowsRemovesSourceOnlyAfterSuccess() throws {
        let sourceDirectory = try makeFolder("Source", under: root)
        let destinationDirectory = try makeFolder("Destination", under: root)
        let source = sourceDirectory.appendingPathComponent("move-me.txt")
        try Data("moved".utf8).write(to: source)

        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.clearContents() }

        let sourceWindow = makeController(start: sourceDirectory)
        sourceWindow.clipPasteboard = pasteboard
        let destinationWindow = makeController(start: destinationDirectory, cascadeIndex: 1)
        destinationWindow.clipPasteboard = pasteboard

        let sourceTable = try XCTUnwrap(locate(in: sourceWindow).table)
        waitUntil { sourceTable.numberOfRows == 1 }
        sourceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sourceWindow.cut(nil)

        XCTAssertEqual(ClipboardService.read(from: pasteboard)?.isCut, true)

        destinationWindow.paste(nil)
        let moved = destinationDirectory.appendingPathComponent("move-me.txt")
        waitUntil { fileManager.fileExists(atPath: moved.path) && !fileManager.fileExists(atPath: source.path) }
        XCTAssertTrue(fileManager.fileExists(atPath: moved.path))
        XCTAssertFalse(fileManager.fileExists(atPath: source.path), "The source is removed after a successful move")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "moved")

        // A fully successful cut/paste clears the cut clipboard.
        waitUntil { ClipboardService.read(from: pasteboard) == nil }
        XCTAssertNil(ClipboardService.read(from: pasteboard))
    }

    func testPasteIsDisabledWithoutFilesOnPasteboard() throws {
        let start = try makeFolder("Start", under: root)
        let window = makeController(start: start)
        window.clipPasteboard = makePrivatePasteboard()
        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(ExplorerWindowController.paste(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(window.validateMenuItem(pasteItem))
    }
}

// Get Info sheet construction.
extension ExplorerWindowSmokeTests {
    func testInfoSheetShowsMetadata() throws {
        let start = try makeFolder("Start", under: root)
        let file = start.appendingPathComponent("info.txt")
        try Data("hello".utf8).write(to: file)
        let controller = makeController(start: start)

        guard let window = controller.window else {
            return XCTFail("Missing window")
        }
        InfoSheetController.present(urls: [file], in: window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        defer { window.endSheet(sheet) }

        let views = descendants(of: try XCTUnwrap(sheet.contentView))
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(textView.string.contains("info.txt"))
        XCTAssertTrue(textView.string.contains("Path:"))
        XCTAssertGreaterThan(textView.frame.height, 100, "The info text view must be laid out with usable height")
    }
}

// Tree expansion and refresh.
extension ExplorerWindowSmokeTests {
    func testRefreshPreservesTreeExpansion() throws {
        // The filesystem root is a real, non-symlinked path, so it can always
        // be located in the tree.
        let controller = makeController(start: URL(fileURLWithPath: "/", isDirectory: true))
        let outline = try XCTUnwrap(locate(in: controller).outline)
        waitUntil { outline.numberOfRows >= 1 }

        func rootNode() -> TreeNode? {
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? TreeNode,
                   node.url.standardizedFileURL.path == "/" {
                    return node
                }
            }
            return nil
        }

        let node = try XCTUnwrap(rootNode(), "Filesystem root is not present in the tree")
        outline.expandItem(node)
        waitUntil { outline.numberOfRows > 1 }
        XCTAssertTrue(outline.isItemExpanded(node))

        controller.refresh(nil)
        waitUntil { outline.numberOfRows > 1 }

        // Refresh rebuilds node caches; locate the new node by path and verify
        // the branch is still expanded.
        let refreshed = try XCTUnwrap(rootNode())
        XCTAssertTrue(outline.isItemExpanded(refreshed), "Refresh must preserve expansion")
    }
}

/// Direct tree refresh behavior (targeted invalidation).
final class DirectoryTreeTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        root = fileManager.temporaryDirectory
            .appendingPathComponent("files-tree-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fileManager.fileExists(atPath: root.path) {
            try? fileManager.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func node(in tree: DirectoryTreeController, path: String) -> TreeNode? {
        for row in 0..<tree.outlineView.numberOfRows {
            if let node = tree.outlineView.item(atRow: row) as? TreeNode,
               node.url.standardizedFileURL.path == path {
                return node
            }
        }
        return nil
    }

    func testTargetedRefreshKeepsExpandedBranchAndAddsNewChild() throws {
        // Use the physical temp path so the tree (rooted at /) can reveal it.
        let physicalRoot = root.resolvingSymlinksInPath()
        let start = physicalRoot.appendingPathComponent("Start", isDirectory: true)
        try fileManager.createDirectory(at: start.appendingPathComponent("Existing"), withIntermediateDirectories: true)

        let tree = DirectoryTreeController()
        // /private is flagged hidden on macOS; show hidden folders so the
        // physical temp path can be revealed in the tree.
        tree.includeHidden = true
        tree.reveal(start)
        let startNode = try XCTUnwrap(node(in: tree, path: start.path))
        tree.outlineView.expandItem(startNode)
        XCTAssertTrue(tree.outlineView.isItemExpanded(startNode))
        let rowsBefore = tree.outlineView.numberOfRows

        let added = start.appendingPathComponent("Added", isDirectory: true)
        try fileManager.createDirectory(at: added, withIntermediateDirectories: true)

        tree.refresh(changedPaths: [start.path])

        // The parent's child cache is invalidated too, so locate the refreshed
        // node by path; expansion is preserved by path.
        let refreshedStart = try XCTUnwrap(node(in: tree, path: start.path))
        XCTAssertTrue(
            tree.outlineView.isItemExpanded(refreshedStart),
            "Targeted refresh must not collapse expanded branches"
        )
        XCTAssertGreaterThan(tree.outlineView.numberOfRows, rowsBefore)

        var foundAdded = false
        for row in 0..<tree.outlineView.numberOfRows {
            if let candidate = tree.outlineView.item(atRow: row) as? TreeNode,
               candidate.name == "Added" {
                foundAdded = true
                break
            }
        }
        XCTAssertTrue(foundAdded, "New child directories must appear after a targeted refresh")
    }
}

// List scroll position when entering a new directory.
extension ExplorerWindowSmokeTests {
    /// The table header lives inside the scroll view's content geometry, so the
    /// true top of the listing is -headerHeight. At that position row 0 starts
    /// below the header and is actually visible.
    private func assertListingIsAtTop(
        _ table: NSTableView,
        _ scrollView: NSScrollView,
        in controller: ExplorerWindowController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let root = controller.window?.contentView else {
            XCTFail("Window has no content view", file: file, line: line)
            return
        }
        let headerHeight = max(0, table.headerView?.frame.height ?? 0)
        let clipView = scrollView.contentView
        XCTAssertEqual(
            clipView.bounds.origin.y,
            -headerHeight,
            accuracy: 0.5,
            "Expected the header-aware top (-\(headerHeight)); got \(clipView.bounds.origin.y)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(table.frame.height, 0, file: file, line: line)

        if let header = table.headerView {
            let headerRect = header.convert(header.bounds, to: root)
            let row0Rect = table.convert(table.rect(ofRow: 0), to: root)
            XCTAssertGreaterThanOrEqual(
                row0Rect.minY,
                headerRect.maxY - 0.5,
                "The first row must start below the table header (header=\(headerRect), row0=\(row0Rect))",
                file: file,
                line: line
            )
            XCTAssertTrue(
                row0Rect.intersects(root.bounds),
                "The first row must be inside the window (row0=\(row0Rect), root=\(root.bounds))",
                file: file,
                line: line
            )
        }

        let visibleRows = table.rows(in: table.visibleRect)
        XCTAssertTrue(
            NSLocationInRange(0, visibleRows),
            "The first row must be inside the visible rect, got rows \(visibleRows)",
            file: file,
            line: line
        )
    }

    func testNavigatingToDirectoryResetsListScrollToTop() throws {
        let parent = try makeFolder("Parent", under: root)
        let child = try makeFolder("Child", under: root)
        for index in 0..<150 {
            try Data("p".utf8).write(to: parent.appendingPathComponent(String(format: "parent-%03d.txt", index)))
        }
        for index in 0..<60 {
            try Data("c".utf8).write(to: child.appendingPathComponent(String(format: "child-%03d.txt", index)))
        }

        let controller = makeController(start: parent)
        let table = try XCTUnwrap(locate(in: controller).table)
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        waitUntil { table.numberOfRows == 150 }
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let maximumY = max(0, table.bounds.height - clipView.bounds.height)
        XCTAssertGreaterThan(maximumY, 0, "The parent listing must be scrollable for this test")
        clipView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(clipView)
        XCTAssertGreaterThan(clipView.bounds.origin.y, 0)

        // Simulate clicking a row before opening the directory.
        table.selectRowIndexes(IndexSet(integer: 149), byExtendingSelection: false)

        XCTAssertTrue(controller.navigate(to: child))
        waitUntil { table.numberOfRows == 60 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(controller.currentDirectory.path, child.standardizedFileURL.path)
        assertListingIsAtTop(table, scrollView, in: controller)
    }

    func testRefreshDuringDirectoryChangeKeepsListAtTop() throws {
        let parent = try makeFolder("Parent", under: root)
        let child = try makeFolder("Child", under: root)
        for index in 0..<150 {
            try Data("p".utf8).write(to: parent.appendingPathComponent(String(format: "parent-%03d.txt", index)))
        }
        for index in 0..<60 {
            try Data("c".utf8).write(to: child.appendingPathComponent(String(format: "child-%03d.txt", index)))
        }

        let controller = makeController(start: parent)
        let table = try XCTUnwrap(locate(in: controller).table)
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        waitUntil { table.numberOfRows == 150 }
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let maximumY = max(0, table.bounds.height - clipView.bounds.height)
        XCTAssertGreaterThan(maximumY, 0)
        clipView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(clipView)
        XCTAssertGreaterThan(clipView.bounds.origin.y, 0)

        XCTAssertTrue(controller.navigate(to: child))
        // Simulate a directory-monitor refresh racing with the navigation load.
        controller.refresh(nil)
        waitUntil { table.numberOfRows == 60 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(controller.currentDirectory.path, child.standardizedFileURL.path)
        assertListingIsAtTop(table, scrollView, in: controller)
    }

    func testRefreshAfterNavigationKeepsFirstRowVisible() throws {
        let parent = try makeFolder("Parent", under: root)
        let child = try makeFolder("Child", under: root)
        for index in 0..<40 {
            try Data("p".utf8).write(to: parent.appendingPathComponent(String(format: "parent-%03d.txt", index)))
        }
        for index in 0..<30 {
            try Data("c".utf8).write(to: child.appendingPathComponent(String(format: "child-%03d.txt", index)))
        }

        let controller = makeController(start: parent)
        let table = try XCTUnwrap(locate(in: controller).table)
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        waitUntil { table.numberOfRows == 40 }
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.navigate(to: child))
        waitUntil { table.numberOfRows == 30 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assertListingIsAtTop(table, scrollView, in: controller)

        // A refresh that arrives after navigation must preserve the
        // header-aware top (-headerHeight), not clamp it to zero.
        controller.refresh(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        assertListingIsAtTop(table, scrollView, in: controller)
    }

    func testFirstRowVisibleForSingleEntryDirectory() throws {
        let start = try makeFolder("Single", under: root)
        try Data("one".utf8).write(to: start.appendingPathComponent("only-file.txt"))
        let controller = makeController(start: start)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1728, height: 994), display: true)
        controller.window?.layoutIfNeeded()

        let table = try XCTUnwrap(locate(in: controller).table)
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        waitUntil { table.numberOfRows == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        assertListingIsAtTop(table, scrollView, in: controller)
    }

    func testSingleEntryAfterNavigationShowsFirstRow() throws {
        let parent = try makeFolder("Parent", under: root)
        let child = try makeFolder("SingleChild", under: root)
        for index in 0..<150 {
            try Data("p".utf8).write(to: parent.appendingPathComponent(String(format: "parent-%03d.txt", index)))
        }
        try Data("one".utf8).write(to: child.appendingPathComponent("only-file.txt"))

        let controller = makeController(start: parent)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1728, height: 994), display: true)
        let table = try XCTUnwrap(locate(in: controller).table)
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        waitUntil { table.numberOfRows == 150 }
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let maximumY = max(0, table.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(clipView)
        table.selectRowIndexes(IndexSet(integer: 149), byExtendingSelection: false)

        XCTAssertTrue(controller.navigate(to: child))
        waitUntil { table.numberOfRows == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        assertListingIsAtTop(table, scrollView, in: controller)
    }
}
