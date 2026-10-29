import AppKit
import XCTest

final class ClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use a private named pasteboard: tests never touch the user's
        // general clipboard.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("files-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDownWithError() throws {
        pasteboard.clearContents()
        pasteboard = nil
        try super.tearDownWithError()
    }

    private func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }

    func testCopyRoundTrip() {
        let urls = urls(["/Users/example/a.txt", "/Users/example/b.txt"])
        XCTAssertTrue(ClipboardService.write(urls: urls, cut: false, to: pasteboard))

        let snapshot = ClipboardService.read(from: pasteboard)
        XCTAssertEqual(snapshot?.urls.map { $0.path }, urls.map { $0.path })
        XCTAssertEqual(snapshot?.isCut, false)
        XCTAssertTrue(ClipboardService.cutPaths(from: pasteboard).isEmpty)
    }

    func testCutRoundTrip() {
        let urls = urls(["/Users/example/a.txt", "/Users/example/b.txt"])
        XCTAssertTrue(ClipboardService.write(urls: urls, cut: true, to: pasteboard))

        let snapshot = ClipboardService.read(from: pasteboard)
        XCTAssertEqual(snapshot?.urls.map { $0.path }, urls.map { $0.path })
        XCTAssertEqual(snapshot?.isCut, true)
        XCTAssertEqual(
            ClipboardService.cutPaths(from: pasteboard),
            Set(urls.map { $0.path })
        )
    }

    func testReplacingClipboardRemovesCutIntent() {
        let urls = urls(["/Users/example/a.txt"])
        ClipboardService.write(urls: urls, cut: true, to: pasteboard)

        XCTAssertTrue(ClipboardService.write(urls: urls, cut: false, to: pasteboard))
        XCTAssertEqual(ClipboardService.read(from: pasteboard)?.isCut, false)
        XCTAssertTrue(ClipboardService.cutPaths(from: pasteboard).isEmpty)
    }

    func testClearedClipboardHasNoSnapshot() {
        ClipboardService.write(urls: urls(["/Users/example/a.txt"]), cut: true, to: pasteboard)
        pasteboard.clearContents()
        XCTAssertNil(ClipboardService.read(from: pasteboard))
    }

    func testNonFilePasteboardContentsAreIgnored() {
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        XCTAssertNil(ClipboardService.read(from: pasteboard))
    }

    func testSeparatePasteboardsKeepIndependentCutState() {
        let other = NSPasteboard(name: NSPasteboard.Name("files-tests-\(UUID().uuidString)"))
        other.clearContents()
        defer { other.clearContents() }

        let urls = urls(["/Users/example/a.txt"])
        ClipboardService.write(urls: urls, cut: true, to: pasteboard)
        ClipboardService.write(urls: urls, cut: false, to: other)

        XCTAssertEqual(ClipboardService.read(from: pasteboard)?.isCut, true)
        XCTAssertEqual(ClipboardService.read(from: other)?.isCut, false)
    }

    func testRewritingCutSnapshotClearsWhenEmpty() {
        let urls = urls(["/Users/example/a.txt"])
        ClipboardService.write(urls: urls, cut: true, to: pasteboard)

        ClipboardService.rewriteCutSnapshotIfNeeded(remaining: [], to: pasteboard)
        XCTAssertNil(ClipboardService.read(from: pasteboard))
    }

    func testRewritingCutSnapshotKeepsRemainingItems() {
        let first = "/Users/example/a.txt"
        let second = "/Users/example/b.txt"
        ClipboardService.write(urls: urls([first, second]), cut: true, to: pasteboard)

        ClipboardService.rewriteCutSnapshotIfNeeded(remaining: urls([second]), to: pasteboard)
        let snapshot = ClipboardService.read(from: pasteboard)
        XCTAssertEqual(snapshot?.urls.map { $0.path }, [second])
        XCTAssertEqual(snapshot?.isCut, true)
    }

    func testDropPasteboardItemUsesFileURLRepresentation() {
        let item = DragDropCoordinator.pasteboardItem(for: URL(fileURLWithPath: "/Users/example/a.txt"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let read = ClipboardService.fileURLs(from: pasteboard)
        XCTAssertEqual(read?.map { $0.path }, ["/Users/example/a.txt"])
    }
}
