import AppKit

/// The detailed directory listing (Name / Date Modified / Type / Size).
///
/// Enumeration and metadata reads happen on a background queue. The controller
/// keeps the last loaded listing, restores selection and scroll position across
/// refreshes, and routes every mutation through the window controller
/// (`onCommitRename`, `onDrop`).
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let tableView: FileTableView
    let scrollView: NSScrollView

    var onOpen: ((URL) -> Void)?
    var onContextMenu: (([URL], URL?) -> NSMenu?)?
    var onDrop: (([URL], URL, NSDragOperation) -> Bool)?
    var onCommitRename: ((URL, String) -> Void)?
    var onLoadError: ((String?) -> Void)?
    var onSelectionChange: (() -> Void)?

    private let preferences: Preferences
    private(set) var directory: URL?
    private(set) var items: [FileSystemItem] = []
    private(set) var includeHidden = false
    private(set) var sortKey: SortKey = .name
    private(set) var ascending = true

    /// Paths of items currently on the pasteboard with cut intent, dimmed in
    /// the list.
    var cutPaths: Set<String> = [] {
        didSet {
            guard oldValue != cutPaths, renameEditor == nil else { return }
            tableView.reloadData()
        }
    }

    var isRenaming: Bool { renameEditor != nil }

    private var loadToken = UUID()
    private var needsScrollToTop = false
    private var renameEditor: NSTextField?
    private var renamingURL: URL?
    private var renameOriginalName = ""
    private let dateFormatter = DateFormatter()

    init(preferences: Preferences) {
        self.preferences = preferences
        tableView = FileTableView()
        scrollView = NSScrollView()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        super.init()
        if let storedKey = preferences.sortKey, let key = SortKey(rawValue: storedKey) {
            sortKey = key
        }
        ascending = preferences.sortAscending
        configureTable()
    }

    // MARK: - Setup

    private func configureTable() {
        let name = makeColumn("name", title: "Name", width: 300, minWidth: 140)
        let modified = makeColumn("dateModified", title: "Date Modified", width: 170, minWidth: 110)
        let type = makeColumn("type", title: "Type", width: 120, minWidth: 70)
        let size = makeColumn("size", title: "Size", width: 90, minWidth: 60, alignment: .right)
        for column in [name, modified, type, size] {
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)]
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.style = .fullWidth
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.menu = NSMenu()
        tableView.contextMenuProvider = { [weak self] row in
            guard let self else { return nil }
            return self.onContextMenu?(self.selectedURLs, self.directory)
        }
        tableView.onReturn = { [weak self] in
            guard let self, let url = self.selectedURLs.first else { return }
            self.onOpen?(url)
        }
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        tableView.autoresizingMask = [.width]
    }

    private func makeColumn(
        _ identifier: String,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        alignment: NSTextAlignment = .left
    ) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = preferences.columnWidth(for: identifier) ?? width
        column.minWidth = minWidth
        column.maxWidth = 1200
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        return column
    }

    // MARK: - Loading

    func load(
        directory: URL,
        includeHidden: Bool,
        selecting: Set<String> = [],
        completion: (() -> Void)? = nil
    ) {
        let isNewDirectory = self.directory?.standardizedFileURL.path != directory.standardizedFileURL.path
        self.directory = directory
        self.includeHidden = includeHidden
        if isNewDirectory {
            // Reset immediately, before the asynchronous listing load. A
            // directory-monitor refresh can start and capture the scroll
            // position before the new listing has been installed; without
            // this, it would carry the previous directory's offset into the
            // new directory and win the load-token race.
            needsScrollToTop = true
            scrollToTop()
        }
        reload(selecting: selecting, resetScroll: isNewDirectory, completion: completion)
    }

    func reload(
        selecting: Set<String> = [],
        resetScroll: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let directory else { return }
        finishRenameEditor()
        let token = UUID()
        loadToken = token
        let hidden = includeHidden
        let key = sortKey
        let ascending = ascending
        let selection = selecting.isEmpty ? Set(selectedURLs.map { $0.path }) : selecting
        let shouldScrollToTop = resetScroll || needsScrollToTop
        let scrollOrigin = scrollView.contentView.bounds.origin

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome: Result<[FileSystemItem], Error>
            do {
                var loaded = try DirectoryListing.items(in: directory, includeHidden: hidden)
                loaded = DirectoryListing.sort(loaded, by: key, ascending: ascending)
                outcome = .success(loaded)
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadToken == token else { return }
                switch outcome {
                case .success(let loaded):
                    self.items = loaded
                    self.modelChanged()
                    self.restoreSelection(paths: selection)
                    if shouldScrollToTop {
                        self.scrollToTop()
                        self.needsScrollToTop = false
                    } else {
                        self.restoreScroll(origin: scrollOrigin)
                    }
                    self.onLoadError?(nil)
                case .failure(let error):
                    self.items = []
                    self.modelChanged()
                    if shouldScrollToTop {
                        self.scrollToTop()
                        self.needsScrollToTop = false
                    }
                    self.onLoadError?(error.localizedDescription)
                }
                completion?()
            }
        }
    }

    /// Re-sorts the already loaded items without touching the filesystem.
    func applySort() {
        let selection = Set(selectedURLs.map { $0.path })
        let scrollOrigin = scrollView.contentView.bounds.origin
        items = DirectoryListing.sort(items, by: sortKey, ascending: ascending)
        modelChanged()
        restoreSelection(paths: selection)
        restoreScroll(origin: scrollOrigin)
    }

    private func modelChanged() {
        if renameEditor != nil { finishRenameEditor() }
        tableView.reloadData()
    }

    private func restoreSelection(paths: Set<String>) {
        guard !paths.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        var indexes = IndexSet()
        for (index, item) in items.enumerated() where paths.contains(item.url.path) {
            indexes.insert(index)
        }
        if indexes.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    private func scrollToTop() {
        // NSScrollView places the table header inside the scroll view's
        // content area. The true top is therefore -headerHeight, not zero;
        // scrolling to zero would put the first row underneath the header.
        let clipView = scrollView.contentView
        let headerHeight = max(0, tableView.headerView?.frame.height ?? 0)
        let top = NSPoint(x: 0, y: clipView.isFlipped ? -headerHeight : 0)
        clipView.scroll(to: top)
        scrollView.reflectScrolledClipView(clipView)
        tableView.needsDisplay = true
    }

    private func restoreScroll(origin: NSPoint) {
        tableView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        // The header occupies the top of the scroll content, so the valid top
        // is -headerHeight. Clamping to zero here would scroll the first row
        // under the header on a later refresh/sort.
        let headerHeight = max(0, tableView.headerView?.frame.height ?? 0)
        let top = clipView.isFlipped ? -headerHeight : 0
        let maximumY = max(top, top + tableView.bounds.height - clipView.bounds.height)
        let point = NSPoint(x: 0, y: min(max(origin.y, top), maximumY))
        clipView.scroll(to: point)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Selection

    var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < items.count else { return nil }
            return items[row].url
        }
    }

    func select(url: URL) {
        guard let row = items.firstIndex(where: { $0.url.path == url.standardizedFileURL.path }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func selectAll() {
        tableView.selectAll(nil)
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        onOpen?(items[row].url)
    }

    // MARK: - Inline rename

    func beginRename(url: URL, initialText: String? = nil) {
        finishRenameEditor()
        guard let row = items.firstIndex(where: { $0.url.path == url.standardizedFileURL.path }) else { return }
        let item = items[row]
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let nameField = cell.textField else { return }
        cell.layoutSubtreeIfNeeded()

        let editor = NSTextField(frame: nameField.frame.insetBy(dx: -2, dy: -1))
        editor.autoresizingMask = [.width, .height]
        editor.font = nameField.font ?? .systemFont(ofSize: 12)
        editor.isBezeled = true
        editor.bezelStyle = .squareBezel
        editor.drawsBackground = true
        editor.usesSingleLineMode = true
        editor.delegate = self
        editor.stringValue = initialText ?? item.name
        cell.addSubview(editor)
        nameField.isHidden = true

        renameEditor = editor
        renamingURL = item.url
        renameOriginalName = item.name
        tableView.window?.makeFirstResponder(editor)
        selectName(in: editor, item: item)
    }

    private func selectName(in editor: NSTextField, item: FileSystemItem) {
        guard let fieldEditor = editor.currentEditor() else { return }
        let name = editor.stringValue as NSString
        var length = name.length
        if !item.isDirectory {
            let base = name.deletingPathExtension
            if !base.isEmpty && base != name as String {
                length = min(length, max(1, (base as NSString).length))
            }
        }
        fieldEditor.selectedRange = NSRange(location: 0, length: length)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let editor = renameEditor, (obj.object as? NSTextField) === editor else { return }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        let text = editor.stringValue
        let url = renamingURL
        finishRenameEditor()
        guard movement != NSCancelTextMovement, let url else { return }
        if text != renameOriginalName {
            onCommitRename?(url, text)
        }
    }

    private func finishRenameEditor() {
        guard let editor = renameEditor else { return }
        renameEditor = nil
        renamingURL = nil
        if let cell = editor.superview as? NSTableCellView {
            cell.textField?.isHidden = false
        }
        editor.delegate = nil
        if editor.currentEditor() != nil {
            editor.abortEditing()
        }
        editor.removeFromSuperview()
    }

    // MARK: - NSTableView data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let newKey = SortKey(rawValue: key) else {
            return
        }
        sortKey = newKey
        ascending = descriptor.ascending
        preferences.sortKey = newKey.rawValue
        preferences.sortAscending = descriptor.ascending
        applySort()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < items.count else { return nil }
        return DragDropCoordinator.pasteboardItem(for: items[row].url)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let destination = dropDestination(row: row, dropOperation: dropOperation) else { return [] }
        let urls = DragDropCoordinator.fileURLs(from: info)
        let operation = DragDropCoordinator.proposedOperation(for: urls, destination: destination, info: info)
        if operation != [] {
            if dropOperation == .on, row >= 0, row < items.count, items[row].isDirectory {
                tableView.setDropRow(row, dropOperation: .on)
            } else if row >= 0 {
                tableView.setDropRow(row, dropOperation: .above)
            }
        }
        return operation
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let destination = dropDestination(row: row, dropOperation: dropOperation) else { return false }
        let urls = DragDropCoordinator.fileURLs(from: info)
        let operation = DragDropCoordinator.proposedOperation(for: urls, destination: destination, info: info)
        guard operation != [] else { return false }
        return onDrop?(urls, destination, operation) ?? false
    }

    private func dropDestination(row: Int, dropOperation: NSTableView.DropOperation) -> URL? {
        if dropOperation == .on, row >= 0, row < items.count, items[row].isDirectory {
            return items[row].url
        }
        return directory
    }

    // MARK: - NSTableView delegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row >= 0, row < items.count else { return nil }
        let item = items[row]
        switch tableColumn.identifier.rawValue {
        case "name":
            let identifier = NSUserInterfaceItemIdentifier("NameCell")
            let cell = reusedCell(identifier: identifier) ?? makeNameCell(identifier: identifier)
            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.toolTip = item.url.path
            let isCut = cutPaths.contains(item.url.standardizedFileURL.path)
            cell.textField?.textColor = isCut ? .secondaryLabelColor : .labelColor
            cell.alphaValue = isCut ? 0.6 : 1
            return cell
        case "dateModified":
            let identifier = NSUserInterfaceItemIdentifier("DateCell")
            let cell = reusedCell(identifier: identifier) ?? makeTextCell(identifier: identifier)
            cell.textField?.stringValue = item.modificationDate.map { dateFormatter.string(from: $0) } ?? "—"
            cell.textField?.textColor = .labelColor
            cell.alphaValue = 1
            return cell
        case "type":
            let identifier = NSUserInterfaceItemIdentifier("TypeCell")
            let cell = reusedCell(identifier: identifier) ?? makeTextCell(identifier: identifier)
            cell.textField?.stringValue = item.kind
            cell.textField?.textColor = .labelColor
            cell.alphaValue = 1
            return cell
        case "size":
            let identifier = NSUserInterfaceItemIdentifier("SizeCell")
            let cell = reusedCell(identifier: identifier) ?? makeTextCell(identifier: identifier)
            cell.textField?.alignment = .right
            cell.textField?.stringValue = (item.isDirectory || item.isPackage)
                ? "—"
                : ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
            cell.textField?.textColor = .labelColor
            cell.alphaValue = 1
            return cell
        default:
            return nil
        }
    }

    private func reusedCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView? {
        tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
    }

    private func makeNameCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        preferences.setColumnWidth(column.width, for: column.identifier.rawValue)
    }
}

/// Table view with Explorer-style context-click selection, Return-to-open and
/// copy/move drag support.
final class FileTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var onReturn: (() -> Void)?
    private(set) var contextRow = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        contextRow = row
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return contextMenuProvider?(row)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        contextRow = row
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Return or keypad Enter opens the selection.
        if event.keyCode == 36 || event.keyCode == 76 {
            guard !event.modifierFlags.contains(.command), selectedRow >= 0 else {
                super.keyDown(with: event)
                return
            }
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .move]
    }
}
