import AppKit
import UniformTypeIdentifiers

/// One independent explorer window: own history, current directory, selection,
/// tree expansion and file-list state. Shared behavior (file operations,
/// clipboard formats, preferences) lives in shared services.
final class ExplorerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    private(set) var currentDirectory: URL
    private let preferences: Preferences
    private let treeController: DirectoryTreeController
    private let fileList: FileListController
    private let pathBar: PathBarController
    private let navigationBar: NavigationBarView
    private let splitView: NSSplitView
    private let errorLabel: NSTextField
    private let monitor = DirectoryMonitor()

    private var history: NavigationHistory
    private var rootView: ExplorerRootView?
    private var volumeObservers: [NSObjectProtocol] = []
    private var hasAppliedInitialLayout = false
    private var isPerformingOperation = false
    private var applyToAllConflicts: ConflictResolution?
    private var progressPanel: OperationProgressPanel?
    private var cutPaths: Set<String> = []
    private var monitorUpdateScheduled = false

    /// Pasteboard used for copy/cut/paste. Injectable so tests can use a
    /// private pasteboard instead of the user's general clipboard.
    var clipPasteboard: NSPasteboard = .general

    /// Called after the window closes so the application delegate can release
    /// the controller.
    var onClose: (() -> Void)?

    private enum TransferMode {
        case copy
        case move
    }

    init(startURL: URL, cascadeIndex: Int) {
        let start = startURL.standardizedFileURL
        self.currentDirectory = start
        self.history = NavigationHistory(initialURL: start)
        self.preferences = Preferences.shared
        self.treeController = DirectoryTreeController()
        self.fileList = FileListController(preferences: Preferences.shared)
        self.pathBar = PathBarController()
        self.navigationBar = NavigationBarView(pathField: pathBar.textField)
        self.splitView = NSSplitView()
        self.errorLabel = NSTextField(labelWithString: "")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        configureWindow(cascadeIndex: cascadeIndex)
        buildInterface()
        wireCallbacks()
        observeVolumeChanges()
        applyInitialLocation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func configureWindow(cascadeIndex: Int) {
        guard let window else { return }
        window.minSize = NSSize(width: 760, height: 420)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]

        let offset = CGFloat(min(cascadeIndex, 12)) * 24
        if let saved = preferences.windowFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            var frame = saved
            frame.origin.x += offset
            frame.origin.y -= offset
            window.setFrame(constrainedToScreen(frame), display: false)
        } else {
            window.center()
            var frame = window.frame
            frame.origin.x += offset
            frame.origin.y -= offset
            window.setFrame(constrainedToScreen(frame), display: false)
        }
    }

    /// Keeps a restored/cascaded frame visible on the current screen setup.
    private func constrainedToScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else {
            return frame
        }
        let visible = screen.visibleFrame
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.origin.x, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
        return result
    }

    private func buildInterface() {
        errorLabel.isHidden = true
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingMiddle
        errorLabel.maximumNumberOfLines = 1

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(treeController.scrollView)
        splitView.addArrangedSubview(fileList.scrollView)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(261), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        let root = ExplorerRootView(
            navigationBar: navigationBar,
            errorLabel: errorLabel,
            contentView: splitView
        )
        window?.contentView = root
        rootView = root
    }

    private func wireCallbacks() {
        navigationBar.backButton.target = self
        navigationBar.backButton.action = #selector(goBack(_:))
        navigationBar.forwardButton.target = self
        navigationBar.forwardButton.action = #selector(goForward(_:))
        navigationBar.upButton.target = self
        navigationBar.upButton.action = #selector(goUp(_:))
        navigationBar.refreshButton.target = self
        navigationBar.refreshButton.action = #selector(refresh(_:))

        pathBar.onSubmit = { [weak self] text in
            guard let self else { return false }
            do {
                let url = try PathResolver.directoryURL(from: text)
                guard self.navigate(to: url) else { return false }
                self.window?.makeFirstResponder(self.fileList.tableView)
                return true
            } catch {
                self.showInlineError(error.localizedDescription)
                return false
            }
        }
        pathBar.onCancel = { [weak self] in
            guard let self else { return }
            self.clearInlineError()
            self.window?.makeFirstResponder(self.fileList.tableView)
        }

        fileList.onOpen = { [weak self] url in
            self?.open(url)
        }
        fileList.onContextMenu = { [weak self] urls, directory in
            self?.makeContextMenu(urls: urls, backgroundDirectory: directory, isTree: false)
        }
        fileList.onDrop = { [weak self] urls, destination, operation in
            self?.performDrop(items: urls, destination: destination, operation: operation) ?? false
        }
        fileList.onCommitRename = { [weak self] url, newName in
            self?.commitRename(url, newName)
        }
        fileList.onLoadError = { [weak self] message in
            guard let self else { return }
            if let message {
                self.showInlineError(message)
            } else {
                self.clearInlineError()
            }
        }
        fileList.onSelectionChange = { [weak self] in
            self?.updateNavigationButtons()
        }

        treeController.onSelect = { [weak self] url in
            self?.navigate(to: url)
        }
        treeController.onContextMenu = { [weak self] urls in
            self?.makeContextMenu(urls: urls, backgroundDirectory: nil, isTree: true)
        }
        treeController.onDrop = { [weak self] urls, destination, operation in
            self?.performDrop(items: urls, destination: destination, operation: operation) ?? false
        }
        treeController.onExpansionChanged = { [weak self] in
            self?.scheduleMonitorUpdate()
        }

        monitor.onChange = { [weak self] paths in
            self?.handleFileSystemChanges(paths)
        }
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: self.currentDirectory.path, isDirectory: &isDirectory) {
                    self.navigate(to: self.nearestExistingDirectory(from: self.currentDirectory))
                }
                self.treeController.reloadPreservingExpansion(selecting: self.currentDirectory)
                self.scheduleMonitorUpdate()
            }
            volumeObservers.append(token)
        }
    }

    private func applyInitialLocation() {
        updateWindowTitle()
        pathBar.setCurrentPath(currentDirectory.path)
        treeController.includeHidden = preferences.showHiddenFiles
        fileList.load(directory: currentDirectory, includeHidden: preferences.showHiddenFiles)
        treeController.reveal(currentDirectory)
        updateNavigationButtons()
        updateCutIndicators()
        scheduleMonitorUpdate()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !hasAppliedInitialLayout else { return }
        hasAppliedInitialLayout = true
        window?.layoutIfNeeded()
        let width = splitView.bounds.width
        if width > 0 {
            let fraction = preferences.splitFraction ?? 0.3
            let position = max(180, min(CGFloat(width) * CGFloat(fraction), width - 360))
            splitView.setPosition(position, ofDividerAt: 0)
        }
        window?.makeFirstResponder(fileList.tableView)
    }

    // MARK: - Navigation

    @discardableResult
    func navigate(
        to url: URL,
        addToHistory: Bool = true,
        selecting: Set<String> = [],
        then completion: (() -> Void)? = nil
    ) -> Bool {
        guard let target = validatedDirectoryURL(url) else { return false }
        if addToHistory {
            history.navigate(to: target)
        } else {
            history.replaceCurrent(with: target)
        }
        applyLocation(target, selecting: selecting, completion: completion)
        return true
    }

    /// Validates a target directory and displays an inline error when it cannot
    /// be used. The current directory is never changed on failure.
    private func validatedDirectoryURL(_ url: URL) -> URL? {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            showInlineError("The folder “\(target.path)” does not exist.")
            return nil
        }
        guard FileManager.default.isReadableFile(atPath: target.path) else {
            showInlineError("You do not have permission to open “\(target.path)”.")
            return nil
        }
        return target
    }

    private func applyLocation(
        _ target: URL,
        selecting: Set<String>,
        completion: (() -> Void)?
    ) {
        currentDirectory = target
        clearInlineError()
        pathBar.setCurrentPath(target.path)
        updateWindowTitle()
        fileList.load(
            directory: target,
            includeHidden: preferences.showHiddenFiles,
            selecting: selecting,
            completion: completion
        )
        treeController.reveal(target)
        updateNavigationButtons()
        scheduleMonitorUpdate()
    }

    @objc func goBack(_ sender: Any?) {
        guard let target = history.backURL else {
            NSSound.beep()
            return
        }
        // Validate first: a deleted history entry must not move the index.
        guard let validated = validatedDirectoryURL(target) else { return }
        _ = history.goBack()
        applyLocation(validated, selecting: [], completion: nil)
    }

    @objc func goForward(_ sender: Any?) {
        guard let target = history.forwardURL else {
            NSSound.beep()
            return
        }
        guard let validated = validatedDirectoryURL(target) else { return }
        _ = history.goForward()
        applyLocation(validated, selecting: [], completion: nil)
    }

    @objc func goUp(_ sender: Any?) {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent.path != currentDirectory.path else {
            NSSound.beep()
            return
        }
        navigate(to: parent)
    }

    @objc func focusLocation(_ sender: Any?) {
        pathBar.focus()
    }

    @objc func refresh(_ sender: Any?) {
        clearInlineError()
        fileList.reload()
        treeController.reloadPreservingExpansion()
        scheduleMonitorUpdate()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        preferences.showHiddenFiles.toggle()
        fileList.load(directory: currentDirectory, includeHidden: preferences.showHiddenFiles)
        treeController.includeHidden = preferences.showHiddenFiles
        scheduleMonitorUpdate()
    }

    private func updateNavigationButtons() {
        navigationBar.backButton.isEnabled = history.canGoBack
        navigationBar.forwardButton.isEnabled = history.canGoForward
        navigationBar.upButton.isEnabled = currentDirectory.path != "/"
    }

    private func updateWindowTitle() {
        guard let window else { return }
        let name = FileManager.default.displayName(atPath: currentDirectory.path)
        window.title = name
        window.subtitle = currentDirectory.path
        window.representedURL = currentDirectory
    }

    private func nearestExistingDirectory(from url: URL) -> URL {
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    // MARK: - Inline errors

    private func showInlineError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        rootView?.refreshLayout()
    }

    private func clearInlineError() {
        guard !errorLabel.isHidden else { return }
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        rootView?.refreshLayout()
    }

    // MARK: - Monitor

    private func scheduleMonitorUpdate() {
        guard !monitorUpdateScheduled else { return }
        monitorUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.monitorUpdateScheduled = false
            self.updateMonitorTargets()
        }
    }

    private func updateMonitorTargets() {
        guard window != nil else { return }
        var paths = [currentDirectory.path]
        paths.append(contentsOf: treeController.expandedPaths())
        monitor.setWatchedPaths(paths)
    }

    private func handleFileSystemChanges(_ paths: [String]) {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: currentDirectory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            navigate(to: nearestExistingDirectory(from: currentDirectory))
            treeController.refresh(changedPaths: paths)
            return
        }

        treeController.refresh(changedPaths: paths)
        let affectsCurrent = paths.contains { changed in
            changed == currentDirectory.path
                || VolumeInfo.isSameOrDescendant(URL(fileURLWithPath: changed), of: currentDirectory)
        }
        if affectsCurrent && !fileList.isRenaming {
            fileList.reload()
        }
        updateCutIndicators()
        scheduleMonitorUpdate()
    }

    // MARK: - Selection

    private var activeSelectionURLs: [URL] {
        if firstResponderIsInside(treeController.outlineView) {
            return treeController.selectedURLs
        }
        return fileList.selectedURLs
    }

    /// True while the location bar or the inline rename editor is active.
    /// File/navigation shortcuts are disabled then so native text editing
    /// shortcuts (⌘⌫, ⌘↑, …) keep working.
    private var isTextEditing: Bool {
        window?.firstResponder is NSText
    }

    private func firstResponderIsInside(_ view: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        var current: NSView? = responder
        while let candidate = current {
            if candidate === view { return true }
            current = candidate.superview
        }
        return false
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// True for real folders. Packages (app bundles, documents that are
    /// directory bundles) are opened as documents, matching Finder.
    private func isBrowsableDirectory(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        return !isPackage
    }

    // MARK: - Opening

    @objc func openSelection(_ sender: Any?) {
        let urls = activeSelectionURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        for url in urls {
            open(url)
        }
    }

    private func open(_ url: URL) {
        if isBrowsableDirectory(url) {
            navigate(to: url)
            return
        }
        if !NSWorkspace.shared.open(url) {
            presentAlert(
                title: "Couldn’t open “\(url.lastPathComponent)”",
                message: "No application is available to open this item."
            )
        }
    }

    @objc func revealSelection(_ sender: Any?) {
        let urls = activeSelectionURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func getInfoSelection(_ sender: Any?) {
        let urls = activeSelectionURLs
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        InfoSheetController.present(urls: urls, in: window)
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        copyURLs(activeSelectionURLs)
    }

    @objc func cut(_ sender: Any?) {
        cutURLs(activeSelectionURLs)
    }

    @objc func paste(_ sender: Any?) {
        paste(into: currentDirectory)
    }

    private func copyURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        ClipboardService.write(urls: urls, cut: false, to: clipPasteboard)
        updateCutIndicators()
    }

    private func cutURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        ClipboardService.write(urls: urls, cut: true, to: clipPasteboard)
        updateCutIndicators()
    }

    private func paste(into destination: URL) {
        guard !isPerformingOperation else {
            NSSound.beep()
            return
        }
        guard let snapshot = ClipboardService.read(from: clipPasteboard) else {
            NSSound.beep()
            return
        }
        _ = startTransfer(
            mode: snapshot.isCut ? .move : .copy,
            items: snapshot.urls,
            destination: destination,
            cutPasteboard: snapshot.isCut
        )
    }

    private func updateCutIndicators() {
        let paths = ClipboardService.cutPaths(from: clipPasteboard)
        guard paths != cutPaths else { return }
        cutPaths = paths
        fileList.cutPaths = paths
    }

    // MARK: - Rename / new folder / trash

    @objc func renameSelection(_ sender: Any?) {
        guard let url = activeSelectionURLs.first else {
            NSSound.beep()
            return
        }
        beginRenameInList(url)
    }

    private func beginRenameInList(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.path != currentDirectory.path {
            navigate(to: parent, selecting: [url.path]) { [weak self] in
                self?.fileList.beginRename(url: url)
            }
        } else {
            if !fileList.selectedURLs.contains(where: { $0.path == url.path }) {
                fileList.select(url: url)
            }
            fileList.beginRename(url: url)
        }
    }

    private func commitRename(_ url: URL, _ newName: String) {
        do {
            let newURL = try FileOperations.shared.rename(url, to: newName)
            clearInlineError()
            fileList.reload(selecting: [newURL.path])
            treeController.refresh(changedPaths: [url.deletingLastPathComponent().path])
            scheduleMonitorUpdate()
        } catch {
            presentAlert(title: "Couldn’t rename “\(url.lastPathComponent)”", message: error.localizedDescription)
            DispatchQueue.main.async { [weak self] in
                self?.fileList.beginRename(url: url, initialText: newName)
            }
        }
    }

    @objc func newFolder(_ sender: Any?) {
        createFolder(in: currentDirectory)
    }

    private func createFolder(in directory: URL) {
        guard !isPerformingOperation else {
            NSSound.beep()
            return
        }
        do {
            let url = try FileOperations.shared.createFolder(in: directory)
            if directory.standardizedFileURL.path == currentDirectory.path {
                fileList.reload(selecting: [url.path]) { [weak self] in
                    self?.fileList.beginRename(url: url)
                }
            } else {
                fileList.reload()
            }
            treeController.refresh(changedPaths: [directory.path])
            scheduleMonitorUpdate()
        } catch {
            presentAlert(title: "Couldn’t create a folder", message: error.localizedDescription)
        }
    }

    @objc func moveSelectionToTrash(_ sender: Any?) {
        trash(activeSelectionURLs)
    }

    private func trash(_ urls: [URL]) {
        guard !urls.isEmpty, !isPerformingOperation else {
            NSSound.beep()
            return
        }
        isPerformingOperation = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = FileOperations.shared.moveToTrash(urls)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPerformingOperation = false
                if urls.contains(where: { VolumeInfo.isSameOrDescendant(self.currentDirectory, of: $0) }) {
                    self.navigate(to: self.nearestExistingDirectory(from: self.currentDirectory))
                }
                self.fileList.reload()
                self.treeController.refresh(changedPaths: urls.map { $0.deletingLastPathComponent().path })
                self.scheduleMonitorUpdate()
                self.updateCutIndicators()
                if !result.failures.isEmpty {
                    self.presentResultAlert(result)
                }
            }
        }
    }

    // MARK: - Transfers (shared by paste and drag/drop)

    @discardableResult
    private func startTransfer(
        mode: TransferMode,
        items: [URL],
        destination: URL,
        cutPasteboard: Bool
    ) -> Bool {
        guard !items.isEmpty else { return false }
        guard !isPerformingOperation else {
            NSSound.beep()
            return false
        }
        do {
            try FileOperations.shared.validate(items: items, to: destination)
        } catch {
            presentAlert(
                title: mode == .copy ? "Can’t copy items" : "Can’t move items",
                message: error.localizedDescription
            )
            return false
        }

        isPerformingOperation = true
        applyToAllConflicts = nil

        let panel = OperationProgressPanel(title: mode == .copy ? "Copying…" : "Moving…")
        progressPanel = panel
        panel.present(relativeTo: window)

        let conflictHandler: FileOperations.ConflictHandler = { [weak self] conflict in
            self?.resolveConflict(conflict) ?? .cancel
        }
        let progressHandler: FileOperations.ProgressHandler = { [weak panel] progress in
            DispatchQueue.main.async { panel?.update(progress) }
        }
        let isCancelled: FileOperations.CancelCheck = { panel.isCancelled }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: FileOperationResult
            switch mode {
            case .copy:
                result = FileOperations.shared.copy(
                    items: items,
                    to: destination,
                    conflictHandler: conflictHandler,
                    progress: progressHandler,
                    isCancelled: isCancelled
                )
            case .move:
                result = FileOperations.shared.move(
                    items: items,
                    to: destination,
                    conflictHandler: conflictHandler,
                    progress: progressHandler,
                    isCancelled: isCancelled
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishTransfer(
                    result,
                    mode: mode,
                    items: items,
                    destination: destination,
                    cutPasteboard: cutPasteboard,
                    panel: panel
                )
            }
        }
        return true
    }

    private func finishTransfer(
        _ result: FileOperationResult,
        mode: TransferMode,
        items: [URL],
        destination: URL,
        cutPasteboard: Bool,
        panel: OperationProgressPanel
    ) {
        isPerformingOperation = false
        progressPanel = nil
        applyToAllConflicts = nil
        panel.finish()

        let completedPaths = Set(result.completed.map { $0.path })
        if destination.standardizedFileURL.path == currentDirectory.path {
            fileList.reload(selecting: completedPaths)
        } else {
            fileList.reload()
        }
        treeController.refresh(changedPaths: [destination.path])
        scheduleMonitorUpdate()

        if cutPasteboard {
            // Keep cut intent only for sources that still exist (partial
            // failure or cancellation), otherwise clear the clipboard.
            let remaining = items.filter { FileOperations.shared.itemExists(at: $0) }
            ClipboardService.rewriteCutSnapshotIfNeeded(remaining: remaining, to: clipPasteboard)
        }
        updateCutIndicators()

        if result.hasProblems {
            presentResultAlert(result)
        }
    }

    private func performDrop(items: [URL], destination: URL, operation: NSDragOperation) -> Bool {
        guard !items.isEmpty else { return false }
        if operation == .copy {
            return startTransfer(mode: .copy, items: items, destination: destination, cutPasteboard: false)
        }
        if operation == .move {
            return startTransfer(mode: .move, items: items, destination: destination, cutPasteboard: false)
        }
        return false
    }

    private func resolveConflict(_ conflict: ConflictInfo) -> ConflictResolution {
        if let applyToAllConflicts { return applyToAllConflicts }

        var resolution: ConflictResolution = .cancel
        let ask = { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(conflict.destination.lastPathComponent)” already exists"
            alert.informativeText = "Replace the existing item with “\(conflict.source.lastPathComponent)”?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
            let checkbox = NSButton(
                checkboxWithTitle: "Apply to all remaining conflicts",
                target: nil,
                action: nil
            )
            alert.accessoryView = checkbox
            let response = alert.runModal()
            let choice: ConflictResolution
            switch response {
            case .alertFirstButtonReturn: choice = .replace
            case .alertSecondButtonReturn: choice = .skip
            default: choice = .cancel
            }
            if checkbox.state == .on, choice != .cancel {
                self.applyToAllConflicts = choice
            }
            resolution = choice
        }

        if Thread.isMainThread {
            ask()
        } else {
            DispatchQueue.main.sync(execute: ask)
        }
        return resolution
    }

    // MARK: - Context menus

    private func makeContextMenu(urls: [URL], backgroundDirectory: URL?, isTree: Bool) -> NSMenu? {
        let menu = NSMenu()
        if urls.isEmpty {
            guard !isTree, let directory = backgroundDirectory else { return nil }
            addMenuItem(menu, "New Folder", #selector(contextNewFolder(_:)), represented: directory)
            addMenuItem(
                menu,
                "Paste",
                #selector(contextPaste(_:)),
                represented: directory,
                enabled: ClipboardService.read(from: clipPasteboard) != nil
            )
            menu.addItem(.separator())
            addMenuItem(menu, "Refresh", #selector(refresh(_:)), represented: nil)
            addHiddenFilesItem(to: menu)
            return menu
        }

        addMenuItem(menu, "Open", #selector(contextOpen(_:)), represented: urls)
        if urls.count == 1, !isBrowsableDirectory(urls[0]) {
            menu.addItem(openWithMenuItem(for: urls[0]))
        }
        menu.addItem(.separator())
        addMenuItem(menu, "Cut", #selector(contextCut(_:)), represented: urls)
        addMenuItem(menu, "Copy", #selector(contextCopy(_:)), represented: urls)
        addMenuItem(menu, "Rename", #selector(contextRename(_:)), represented: urls, enabled: urls.count == 1)
        addMenuItem(menu, "Move to Trash", #selector(contextTrash(_:)), represented: urls)
        menu.addItem(.separator())
        addMenuItem(menu, "Reveal in Finder", #selector(contextReveal(_:)), represented: urls)
        addMenuItem(menu, "Get Info", #selector(contextGetInfo(_:)), represented: urls, enabled: urls.count == 1)
        return menu
    }

    private func addMenuItem(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        represented: Any?,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func addHiddenFilesItem(to menu: NSMenu) {
        let item = NSMenuItem(
            title: preferences.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
            action: #selector(toggleHiddenFiles(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    private func openWithMenuItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let applications = NSWorkspace.shared.urlsForApplications(toOpen: url)
        for appURL in applications.prefix(12) {
            let applicationItem = NSMenuItem(
                title: FileManager.default.displayName(atPath: appURL.path),
                action: #selector(contextOpenWithApplication(_:)),
                keyEquivalent: ""
            )
            applicationItem.target = self
            applicationItem.representedObject = OpenWithRequest(urls: [url], applicationURL: appURL)
            submenu.addItem(applicationItem)
        }
        if applications.isEmpty {
            let empty = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: #selector(contextOpenWithOther(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = url
        submenu.addItem(other)
        item.submenu = submenu
        return item
    }

    private func urls(from sender: NSMenuItem) -> [URL] {
        (sender.representedObject as? [URL]) ?? activeSelectionURLs
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        for url in urls(from: sender) { open(url) }
    }

    @objc private func contextCut(_ sender: NSMenuItem) {
        cutURLs(urls(from: sender))
    }

    @objc private func contextCopy(_ sender: NSMenuItem) {
        copyURLs(urls(from: sender))
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        if let url = urls(from: sender).first {
            beginRenameInList(url)
        }
    }

    @objc private func contextTrash(_ sender: NSMenuItem) {
        trash(urls(from: sender))
    }

    @objc private func contextReveal(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting(urls(from: sender))
    }

    @objc private func contextGetInfo(_ sender: NSMenuItem) {
        InfoSheetController.present(urls: urls(from: sender), in: window)
    }

    @objc private func contextNewFolder(_ sender: NSMenuItem) {
        if let directory = sender.representedObject as? URL {
            createFolder(in: directory)
        }
    }

    @objc private func contextPaste(_ sender: NSMenuItem) {
        if let directory = sender.representedObject as? URL {
            paste(into: directory)
        }
    }

    @objc private func contextOpenWithApplication(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenWithRequest else { return }
        open(request.urls, withApplication: request.applicationURL)
    }

    @objc private func contextOpenWithOther(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Open With"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let appURL = panel.url else { return }
            self?.open([url], withApplication: appURL)
        }
    }

    private func open(_ urls: [URL], withApplication appURL: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.presentAlert(title: "Couldn’t open the item", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Alerts

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentResultAlert(_ result: FileOperationResult) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = result.wasCancelled ? "The operation was cancelled" : "Some items were not processed"
        var lines = [result.summary]
        for failure in result.failures.prefix(5) {
            lines.append("• “\(failure.url.lastPathComponent)”: \(failure.error.localizedDescription)")
        }
        if result.failures.count > 5 {
            lines.append("…and \(result.failures.count - 5) more.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = activeSelectionURLs
        switch menuItem.action {
        case #selector(goBack(_:)):
            return history.canGoBack && !isTextEditing
        case #selector(goForward(_:)):
            return history.canGoForward && !isTextEditing
        case #selector(goUp(_:)):
            return currentDirectory.path != "/" && !isTextEditing
        case #selector(focusLocation(_:)), #selector(refresh(_:)):
            return true
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = preferences.showHiddenFiles ? .on : .off
            return true
        case #selector(newFolder(_:)):
            return !isTextEditing && !isPerformingOperation
        case #selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(getInfoSelection(_:)):
            return !isTextEditing && !selection.isEmpty
        case #selector(renameSelection(_:)):
            return !isTextEditing && selection.count == 1 && !isPerformingOperation
        case #selector(moveSelectionToTrash(_:)):
            return !isTextEditing && !selection.isEmpty && !isPerformingOperation
        case #selector(copy(_:)), #selector(cut(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)):
            return ClipboardService.read(from: clipPasteboard) != nil && !isPerformingOperation
        default:
            return true
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 360)
    }

    func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.bounds.width > 0 else { return }
        let fraction = treeController.scrollView.frame.width / splitView.bounds.width
        guard fraction > 0.05 else { return }
        preferences.splitFraction = Double(fraction)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateCutIndicators()
        updateNavigationButtons()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        monitor.stop()
        for token in volumeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        volumeObservers.removeAll()
        onClose?()
    }

    private func saveWindowFrame() {
        guard let window, !window.isMiniaturized else { return }
        preferences.windowFrame = window.frame
    }
}

/// A pasteboard-backed request to open items with a specific application.
private struct OpenWithRequest {
    let urls: [URL]
    let applicationURL: URL
}

// MARK: - Layout views

/// Root content view: navigation bar at the top, optional inline error line,
/// and the tree/listing split view filling the rest.
final class ExplorerRootView: NSView {
    private let navigationBar: NavigationBarView
    private let errorLabel: NSTextField
    private let content: NSView

    private let navigationBarHeight: CGFloat = 42
    private let errorHeight: CGFloat = 20

    init(navigationBar: NavigationBarView, errorLabel: NSTextField, contentView: NSView) {
        self.navigationBar = navigationBar
        self.errorLabel = errorLabel
        self.content = contentView
        super.init(frame: .zero)
        addSubview(navigationBar)
        addSubview(errorLabel)
        addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        navigationBar.frame = NSRect(x: 0, y: 0, width: width, height: navigationBarHeight)
        var y = navigationBarHeight
        if !errorLabel.isHidden {
            errorLabel.frame = NSRect(x: 14, y: y + 1, width: max(0, width - 28), height: 16)
            y += errorHeight
        }
        content.frame = NSRect(x: 0, y: y, width: width, height: max(0, height - y))
    }

    func refreshLayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

/// Back / Forward / Up / Refresh plus the always-editable path field.
final class NavigationBarView: NSView {
    let backButton = NavigationBarView.makeButton(symbol: "chevron.backward", description: "Back")
    let forwardButton = NavigationBarView.makeButton(symbol: "chevron.forward", description: "Forward")
    let upButton = NavigationBarView.makeButton(symbol: "arrow.up", description: "Enclosing Folder")
    let refreshButton = NavigationBarView.makeButton(symbol: "arrow.clockwise", description: "Refresh")
    let pathField: NSTextField

    init(pathField: NSTextField) {
        self.pathField = pathField
        super.init(frame: .zero)
        addSubview(backButton)
        addSubview(forwardButton)
        addSubview(upButton)
        addSubview(refreshButton)
        addSubview(pathField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 26
        let buttonY = (bounds.height - buttonSize) / 2
        var x: CGFloat = 12
        for button in [backButton, forwardButton, upButton, refreshButton] {
            button.frame = NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize)
            x += buttonSize + 5
        }
        let fieldX = x + 7
        pathField.frame = NSRect(
            x: fieldX,
            y: (bounds.height - 24) / 2,
            width: max(80, bounds.width - fieldX - 14),
            height: 24
        )
    }

    static func makeButton(symbol: String, description: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.controlSize = .small
        button.toolTip = description
        button.setAccessibilityLabel(description)
        return button
    }
}
