import AppKit

/// Lazy node in the folder tree. Children are enumerated on demand and cached;
/// only directories are represented, and symbolic-link cycles are refused.
final class TreeNode: NSObject {
    let url: URL
    let name: String
    let depth: Int
    weak var parent: TreeNode?
    private var cachedChildren: [TreeNode]?

    var loadedChildren: [TreeNode]? { cachedChildren }

    init(url: URL, name: String? = nil, parent: TreeNode?, depth: Int) {
        self.url = url.standardizedFileURL
        let candidate = name ?? url.lastPathComponent
        self.name = candidate.isEmpty ? url.path : candidate
        self.parent = parent
        self.depth = depth
        super.init()
    }

    func children(includeHidden: Bool) -> [TreeNode] {
        if let cachedChildren { return cachedChildren }
        let result = loadChildren(includeHidden: includeHidden)
        cachedChildren = result
        return result
    }

    func invalidateChildren() {
        cachedChildren = nil
    }

    func invalidateRecursively() {
        let loaded = cachedChildren
        cachedChildren = nil
        loaded?.forEach { $0.invalidateRecursively() }
    }

    private func loadChildren(includeHidden: Bool) -> [TreeNode] {
        // Guard against pathological deep trees and symlink loops.
        guard depth < 64 else { return [] }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            return []
        }

        var ancestorKeys = Set<String>()
        var walker: TreeNode? = self
        while let node = walker {
            ancestorKeys.insert(VolumeInfo.comparisonKey(node.url))
            walker = node.parent
        }

        var result: [TreeNode] = []
        result.reserveCapacity(urls.count)
        for childURL in urls {
            let values = try? childURL.resourceValues(forKeys: resourceKeys)
            let isLink = values?.isSymbolicLink == true
            var isDirectory = values?.isDirectory == true
            if !isDirectory, isLink {
                // Directory symlinks are traversable tree nodes.
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir) {
                    isDirectory = isDir.boolValue
                }
            }
            guard isDirectory, values?.isPackage != true else { continue }
            if !includeHidden && ((values?.isHidden ?? false) || childURL.lastPathComponent.hasPrefix(".")) {
                continue
            }
            if isLink {
                // Refuse links that resolve to this folder or one of its
                // ancestors (a cycle in the visible tree).
                if ancestorKeys.contains(VolumeInfo.comparisonKey(childURL)) { continue }
            }
            result.append(TreeNode(url: childURL, parent: self, depth: depth + 1))
        }
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
}

final class DirectoryTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView: DirectoryOutlineView
    let scrollView: NSScrollView

    /// Called when the user selects a folder row.
    var onSelect: ((URL) -> Void)?
    /// Builds the context menu for the current tree selection.
    var onContextMenu: (([URL]) -> NSMenu?)?
    /// Performs a validated drop onto a folder row.
    var onDrop: (([URL], URL, NSDragOperation) -> Bool)?
    /// Called when branches are expanded/collapsed so watched paths can update.
    var onExpansionChanged: (() -> Void)?

    var includeHidden: Bool = false {
        didSet {
            guard oldValue != includeHidden else { return }
            reloadPreservingExpansion()
        }
    }

    private var rootNodes: [TreeNode] = []
    private var isSynchronizing = false

    override init() {
        outlineView = DirectoryOutlineView()
        scrollView = NSScrollView()
        super.init()
        configureOutlineView()
        rootNodes = makeRootNodes()
        outlineView.reloadData()
    }

    // MARK: - Setup

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("treeName"))
        column.title = "Folders"
        column.width = 220
        column.minWidth = 100
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = NSMenu()
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outlineView.contextMenuProvider = { [weak self] row in
            guard let self, row >= 0 else { return nil }
            return self.onContextMenu?(self.selectedURLs)
        }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
    }

    // MARK: - Root nodes

    private func makeRootNodes() -> [TreeNode] {
        var nodes: [TreeNode] = []
        let bootURL = URL(fileURLWithPath: "/", isDirectory: true)
        nodes.append(TreeNode(url: bootURL, name: displayName(for: bootURL) ?? "Macintosh HD", parent: nil, depth: 0))

        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let bootIdentifier = VolumeInfo.identifier(of: bootURL)
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .volumeIdentifierKey, .volumeLocalizedNameKey],
            options: []
        )) ?? []

        for volumeURL in volumes {
            let values = try? volumeURL.resourceValues(forKeys: [.isDirectoryKey, .volumeIdentifierKey, .volumeLocalizedNameKey])
            guard values?.isDirectory == true else { continue }
            if let bootIdentifier, let identifier = VolumeInfo.identifier(of: volumeURL), identifier.isEqual(bootIdentifier) {
                continue
            }
            let name = values?.volumeLocalizedName ?? displayName(for: volumeURL) ?? volumeURL.lastPathComponent
            nodes.append(TreeNode(url: volumeURL, name: name, parent: nil, depth: 0))
        }
        return nodes
    }

    private func displayName(for url: URL) -> String? {
        FileManager.default.displayName(atPath: url.path)
    }

    // MARK: - Public queries

    var selectedURLs: [URL] {
        outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? TreeNode)?.url
        }
    }

    var selectedURL: URL? { selectedURLs.first }

    func expandedPaths() -> [String] {
        var paths: [String] = []
        guard outlineView.numberOfRows > 0 else { return paths }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? TreeNode else { continue }
            if outlineView.isItemExpanded(node) {
                paths.append(node.url.path)
            }
        }
        return paths
    }

    // MARK: - Navigation synchronization

    /// Reveals a folder in the tree, expanding ancestors, and selects it.
    /// Programmatic selection does not trigger `onSelect`.
    func reveal(_ url: URL) {
        isSynchronizing = true
        defer { isSynchronizing = false }
        guard let node = node(at: url, expanding: true) else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    /// Reloads the whole tree, restoring expanded branches and selection when
    /// their paths still exist. Unrelated expansion state is preserved.
    func reloadPreservingExpansion(selecting selection: URL? = nil) {
        let expanded = expandedPaths()
        let previousSelection = selection ?? selectedURLs.first
        isSynchronizing = true
        for root in rootNodes { root.invalidateRecursively() }
        rootNodes = makeRootNodes()
        outlineView.reloadData()
        for path in expanded {
            _ = expand(path: path)
        }
        if let previousSelection {
            if let node = node(at: previousSelection, expanding: true) {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }
            } else {
                outlineView.deselectAll(nil)
            }
        }
        isSynchronizing = false
    }

    /// Invalidates caches only for the changed directories and reloads the
    /// outline. Expanded branches keep their expansion state because node
    /// objects are preserved; unaffected caches are not re-enumerated.
    func refresh(changedPaths: [String]) {
        guard !changedPaths.isEmpty else { return }
        let expanded = expandedPaths()
        let selection = selectedURLs.first

        var changedKeys = Set<String>()
        for path in changedPaths {
            let url = URL(fileURLWithPath: path)
            changedKeys.insert(VolumeInfo.comparisonKey(url))
            changedKeys.insert(VolumeInfo.comparisonKey(url.deletingLastPathComponent()))
        }
        var affected = false
        for root in rootNodes {
            if invalidate(root, matching: changedKeys) { affected = true }
        }
        guard affected else { return }

        isSynchronizing = true
        // ReloadData does not reliably keep branch expansion, so re-expand the
        // previously expanded paths. Unaffected branches use their cached
        // children and are not re-enumerated; only changed directories reload.
        outlineView.reloadData()
        for path in expanded {
            _ = expand(path: path)
        }
        if let selection, let node = node(at: selection, expanding: true) {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        isSynchronizing = false
    }

    private func invalidate(_ node: TreeNode, matching keys: Set<String>) -> Bool {
        var affected = false
        if keys.contains(VolumeInfo.comparisonKey(node.url)) {
            node.invalidateChildren()
            affected = true
        }
        // Recurse only into already-loaded branches so refresh stays lazy and
        // never enumerates the whole tree.
        for child in node.loadedChildren ?? [] {
            if invalidate(child, matching: keys) { affected = true }
        }
        return affected
    }

    private func expand(path: String) -> TreeNode? {
        guard let node = node(at: URL(fileURLWithPath: path), expanding: true) else {
            return nil
        }
        // `node(at:expanding:)` expands the ancestors; restoring an expanded
        // branch also requires expanding the node itself.
        outlineView.expandItem(node)
        return node
    }

    private func node(at target: URL, expanding: Bool) -> TreeNode? {
        let target = target.standardizedFileURL
        guard let root = bestRoot(for: target) else { return nil }
        let rootComponents = root.url.pathComponents
        let targetComponents = target.pathComponents
        guard componentsMatch(targetComponents, rootComponents) else { return nil }

        var node = root
        if targetComponents.count == rootComponents.count { return node }
        if expanding { outlineView.expandItem(root) }
        for index in rootComponents.count..<targetComponents.count {
            guard let child = childNode(named: targetComponents[index], in: node) else { return nil }
            node = child
            if expanding && index < targetComponents.count - 1 {
                outlineView.expandItem(node)
            }
        }
        return node
    }

    private func componentsMatch(_ target: [String], _ base: [String]) -> Bool {
        guard target.count >= base.count else { return false }
        for (index, component) in base.enumerated() {
            let candidate = target[index]
            if candidate == component { continue }
            guard candidate.compare(component, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
                return false
            }
        }
        return true
    }

    private func bestRoot(for target: URL) -> TreeNode? {
        rootNodes
            .filter { VolumeInfo.isSameOrDescendant(target, of: $0.url) }
            .max { VolumeInfo.comparisonKey($0.url).count < VolumeInfo.comparisonKey($1.url).count }
    }

    private func childNode(named name: String, in parent: TreeNode) -> TreeNode? {
        let children = parent.children(includeHidden: includeHidden)
        if let exact = children.first(where: { $0.url.lastPathComponent == name }) {
            return exact
        }
        return children.first {
            $0.url.lastPathComponent.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    // MARK: - NSOutlineView data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? TreeNode {
            return node.children(includeHidden: includeHidden).count
        }
        return rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TreeNode {
            return node.children(includeHidden: includeHidden)[index]
        }
        return rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        return !node.children(includeHidden: includeHidden).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? TreeNode else { return nil }
        return DragDropCoordinator.pasteboardItem(for: node.url)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Only folder rows are valid destinations; dropping between rows is
        // not supported.
        guard index == NSOutlineViewDropOnItemIndex,
              let node = item as? TreeNode else {
            return []
        }
        let urls = DragDropCoordinator.fileURLs(from: info)
        let operation = DragDropCoordinator.proposedOperation(for: urls, destination: node.url, info: info)
        if operation != [] {
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return operation
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard index == NSOutlineViewDropOnItemIndex,
              let node = item as? TreeNode else {
            return false
        }
        let urls = DragDropCoordinator.fileURLs(from: info)
        let operation = DragDropCoordinator.proposedOperation(for: urls, destination: node.url, info: info)
        guard operation != [] else { return false }
        return onDrop?(urls, node.url, operation) ?? false
    }

    // MARK: - NSOutlineView delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TreeCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeCell(identifier: identifier)
        }
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        cell.toolTip = node.url.path
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .systemFont(ofSize: 12)
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizing, let url = selectedURL else { return }
        onSelect?(url)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        onExpansionChanged?()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        onExpansionChanged?()
    }
}

/// Outline view that selects a row on right-click (when necessary) before
/// showing its context menu, and advertises copy/move drag support.
final class DirectoryOutlineView: NSOutlineView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(row)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .move]
    }
}
