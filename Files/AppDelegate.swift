import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [ExplorerWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if windowControllers.isEmpty {
            newWindow(nil)
        }
    }

    @objc func newWindow(_ sender: Any?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let controller = ExplorerWindowController(startURL: home, cascadeIndex: windowControllers.count)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindow(nil)
        }
        return true
    }

    /// Show the marketing version only. CFBundleVersion stays in the bundle
    /// for macOS update/cache identity, but is not displayed to the user.
    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Files",
            .applicationVersion: "0.1.0",
            .version: ""
        ])
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

/// Programmatic main menu. File-related commands target the first responder;
/// the window controller that implements them is part of the responder chain.
/// Standard text edit commands use the standard selectors so the field editor
/// keeps its native behavior while the location bar or rename editor is active.
enum MainMenu {
    static func build(appDelegate: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Files")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        addItem(appMenu, "About Files", #selector(AppDelegate.showAboutPanel(_:)), "", [], target: appDelegate)
        appMenu.addItem(.separator())
        addItem(appMenu, "Hide Files", #selector(NSApplication.hide(_:)), "h", [.command])
        addItem(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        addItem(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "", [])
        appMenu.addItem(.separator())
        addItem(appMenu, "Quit Files", #selector(NSApplication.terminate(_:)), "q", [.command])

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        addItem(fileMenu, "New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command], target: appDelegate)
        addItem(fileMenu, "New Folder", #selector(ExplorerWindowController.newFolder(_:)), "N", [.command, .shift])
        addItem(fileMenu, "Open", #selector(ExplorerWindowController.openSelection(_:)), "o", [.command])
        addItem(fileMenu, "Rename", #selector(ExplorerWindowController.renameSelection(_:)), "\u{F705}", [])
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Reveal in Finder", #selector(ExplorerWindowController.revealSelection(_:)), "r", [.command, .shift])
        addItem(fileMenu, "Get Info", #selector(ExplorerWindowController.getInfoSelection(_:)), "i", [.command])
        addItem(fileMenu, "Move to Trash", #selector(ExplorerWindowController.moveSelectionToTrash(_:)), "\u{8}", [.command])
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command])

        // Edit menu (standard selectors; text editing keeps priority)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        addItem(editMenu, "Undo", Selector(("undo:")), "z", [.command])
        addItem(editMenu, "Redo", Selector(("redo:")), "Z", [.command, .shift])
        editMenu.addItem(.separator())
        addItem(editMenu, "Cut", #selector(NSText.cut(_:)), "x", [.command])
        addItem(editMenu, "Copy", #selector(NSText.copy(_:)), "c", [.command])
        addItem(editMenu, "Paste", #selector(NSText.paste(_:)), "v", [.command])
        addItem(editMenu, "Select All", #selector(NSText.selectAll(_:)), "a", [.command])

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        addItem(viewMenu, "Show Hidden Files", #selector(ExplorerWindowController.toggleHiddenFiles(_:)), "H", [.command, .shift])
        addItem(viewMenu, "Refresh", #selector(ExplorerWindowController.refresh(_:)), "r", [.command])

        // Go menu
        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        addItem(goMenu, "Back", #selector(ExplorerWindowController.goBack(_:)), "[", [.command])
        addItem(goMenu, "Forward", #selector(ExplorerWindowController.goForward(_:)), "]", [.command])
        addItem(goMenu, "Enclosing Folder", #selector(ExplorerWindowController.goUp(_:)), "\u{F700}", [.command])
        goMenu.addItem(.separator())
        addItem(goMenu, "Go to Folder…", #selector(ExplorerWindowController.focusLocation(_:)), "l", [.command])

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        addItem(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", [.command])
        addItem(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)), "", [])
        windowMenu.addItem(.separator())
        addItem(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", [])

        NSApp.windowsMenu = windowMenu
        return mainMenu
    }

    @discardableResult
    private static func addItem(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String,
        _ modifiers: NSEvent.ModifierFlags,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }
}
