import AppKit

/// A native "Get Info" sheet showing filesystem metadata for one or more
/// items. This is Files' own panel rather than Finder's, because macOS has no
/// public API for opening Finder's info window.
final class InfoSheetController: NSObject {
    private static var active: [InfoSheetController] = []

    private let window: NSWindow
    private weak var parentWindow: NSWindow?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static func present(urls: [URL], in parent: NSWindow?) {
        guard let parent, !urls.isEmpty else { return }
        let controller = InfoSheetController(urls: urls)
        controller.parentWindow = parent
        active.append(controller)
        parent.beginSheet(controller.window) { _ in
            controller.dismiss()
        }
    }

    private init(urls: [URL]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = urls.count == 1 ? "\(urls[0].lastPathComponent) Info" : "\(urls.count) Items Info"
        self.window = window
        super.init()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        window.contentView = content

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 488, height: 320))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = Self.infoText(for: urls)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let height = max(320, ceil(used.height) + 24)
            textView.setFrameSize(NSSize(width: 488, height: height))
        }
        scrollView.documentView = textView

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close(_:)))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"

        content.addSubview(scrollView)
        content.addSubview(closeButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 90)
        ])
    }

    @objc private func close(_ sender: Any?) {
        parentWindow?.endSheet(window)
    }

    private func dismiss() {
        window.orderOut(nil)
        Self.active.removeAll { $0 === self }
    }

    // MARK: - Text

    private static func infoText(for urls: [URL]) -> String {
        urls.map(infoText(for:)).joined(separator: "\n\n" + String(repeating: "—", count: 40) + "\n\n")
    }

    private static func infoText(for url: URL) -> String {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let type = attributes?[.type] as? FileAttributeType

        var lines: [String] = []
        lines.append("Name: \(url.lastPathComponent)")
        lines.append("Path: \(url.path)")
        if let type {
            lines.append("Kind: \(describe(type))")
        } else {
            lines.append("Kind: Unknown")
        }
        if type == .typeRegular, let size = (attributes?[.size] as? NSNumber)?.int64Value {
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            lines.append("Size: \(formatted) (\(size) bytes)")
        }
        if let created = attributes?[.creationDate] as? Date {
            lines.append("Created: \(dateFormatter.string(from: created))")
        }
        if let modified = attributes?[.modificationDate] as? Date {
            lines.append("Modified: \(dateFormatter.string(from: modified))")
        }
        if let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue {
            lines.append("Permissions: \(permissionString(permissions, type: type)) (\(String(permissions, radix: 8)))")
        }
        if let owner = attributes?[.ownerAccountName] as? String {
            lines.append("Owner: \(owner)")
        }
        if let group = attributes?[.groupOwnerAccountName] as? String {
            lines.append("Group: \(group)")
        }
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            lines.append("Symbolic link: \(target)")
        }
        let volume = VolumeInfo.resourceValues(
            for: url,
            keys: [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        )
        if let volumeName = volume?.volumeLocalizedName {
            lines.append("Volume: \(volumeName)")
        }
        if let capacity = volume?.volumeTotalCapacity {
            lines.append("Volume size: \(ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .file))")
        }
        if let available = volume?.volumeAvailableCapacity {
            lines.append("Available: \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ type: FileAttributeType) -> String {
        switch type {
        case .typeDirectory: return "Folder"
        case .typeRegular: return "Document"
        case .typeSymbolicLink: return "Symbolic link"
        case .typeSocket: return "Socket"
        case .typeCharacterSpecial: return "Character device"
        case .typeBlockSpecial: return "Block device"
        default: return "Unknown"
        }
    }

    private static func permissionString(_ permissions: Int, type: FileAttributeType?) -> String {
        let typeCharacter: Character
        switch type {
        case .typeDirectory: typeCharacter = "d"
        case .typeSymbolicLink: typeCharacter = "l"
        case .typeCharacterSpecial: typeCharacter = "c"
        case .typeBlockSpecial: typeCharacter = "b"
        case .typeSocket: typeCharacter = "s"
        default: typeCharacter = "-"
        }
        let masks: [(Int, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        var result = String(typeCharacter)
        for (mask, character) in masks {
            result.append(permissions & mask != 0 ? character : "-")
        }
        return result
    }
}
