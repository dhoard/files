import AppKit
import XCTest

final class MenuWiringTests: XCTestCase {
    private var menu: NSMenu!
    private var delegate: AppDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        delegate = AppDelegate()
        menu = MainMenu.build(appDelegate: delegate)
    }

    private func item(_ title: String) -> NSMenuItem? {
        find(title, in: menu)
    }

    private func find(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = find(title, in: submenu) {
                return found
            }
        }
        return nil
    }

    func testApplicationMenuUsesFilesName() {
        XCTAssertNotNil(item("About Files"))
        XCTAssertNotNil(item("Hide Files"))
        XCTAssertNotNil(item("Quit Files"))
        XCTAssertEqual(item("Quit Files")?.keyEquivalent, "q")
        XCTAssertEqual(item("Quit Files")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("About Files")?.action, #selector(AppDelegate.showAboutPanel(_:)))
        XCTAssertTrue(item("About Files")?.target === delegate)
    }

    func testWindowAndFileShortcuts() throws {
        let newWindow = try XCTUnwrap(item("New Window"))
        XCTAssertEqual(newWindow.keyEquivalent, "n")
        XCTAssertEqual(newWindow.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(newWindow.target === delegate)

        let newFolder = try XCTUnwrap(item("New Folder"))
        XCTAssertEqual(newFolder.keyEquivalent, "N")
        XCTAssertEqual(newFolder.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertEqual(item("Open")?.keyEquivalent, "o")
        XCTAssertEqual(item("Open")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Move to Trash")?.keyEquivalent, "\u{8}")
        XCTAssertEqual(item("Move to Trash")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Close Window")?.keyEquivalent, "w")
        XCTAssertEqual(item("Close Window")?.keyEquivalentModifierMask, [.command])

        // F2 is intentionally modifier-free (function keys can be captured by
        // macOS settings; documented in the README).
        let rename = try XCTUnwrap(item("Rename"))
        XCTAssertEqual(rename.keyEquivalent, "\u{F705}")
        XCTAssertEqual(rename.keyEquivalentModifierMask, [])
    }

    func testNavigationShortcuts() throws {
        XCTAssertEqual(item("Back")?.keyEquivalent, "[")
        XCTAssertEqual(item("Back")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Forward")?.keyEquivalent, "]")
        XCTAssertEqual(item("Forward")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Enclosing Folder")?.keyEquivalent, "\u{F700}")
        XCTAssertEqual(item("Enclosing Folder")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Go to Folder…")?.keyEquivalent, "l")
        XCTAssertEqual(item("Go to Folder…")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item("Show Hidden Files")?.keyEquivalent, "H")
        XCTAssertEqual(item("Show Hidden Files")?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item("Refresh")?.keyEquivalent, "r")
    }

    func testStandardTextSelectorsAreUsedForEditMenu() throws {
        XCTAssertEqual(item("Cut")?.action, Selector(("cut:")))
        XCTAssertEqual(item("Copy")?.action, Selector(("copy:")))
        XCTAssertEqual(item("Paste")?.action, Selector(("paste:")))
        XCTAssertEqual(item("Select All")?.action, Selector(("selectAll:")))
        XCTAssertNil(item("Copy")?.target, "Edit commands must follow the responder chain")
    }

    func testWindowControllerRespondsToFileCommands() {
        let selectorNames = [
            "newFolder:", "openSelection:", "renameSelection:", "revealSelection:",
            "getInfoSelection:", "moveSelectionToTrash:", "copy:", "cut:", "paste:",
            "goBack:", "goForward:", "goUp:", "focusLocation:", "refresh:", "toggleHiddenFiles:"
        ]
        for name in selectorNames {
            XCTAssertTrue(
                ExplorerWindowController.instancesRespond(to: Selector(name)),
                "ExplorerWindowController does not implement \(name)"
            )
        }
    }

    func testWindowControllerIsInResponderChain() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = ExplorerWindowController(startURL: root, cascadeIndex: 0)
        controller.showWindow(nil)
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        var responder: NSResponder? = window
        var found = false
        while let current = responder {
            if current === controller {
                found = true
                break
            }
            responder = current.nextResponder
        }
        XCTAssertTrue(found, "Menu actions must reach the window controller via the responder chain")

        let backItem = NSMenuItem(title: "Back", action: #selector(ExplorerWindowController.goBack(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(backItem), "Back is disabled at the start of history")
        XCTAssertTrue(controller.window?.isVisible ?? false)
    }
}
