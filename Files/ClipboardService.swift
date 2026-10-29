import AppKit

/// A snapshot of the file URLs currently on a pasteboard and whether they were
/// placed there by a Files "Cut" command.
struct ClipboardSnapshot {
    let urls: [URL]
    let isCut: Bool
}

/// Pasteboard integration.
///
/// Copy writes standard `public.file-url` items, so content can be pasted in
/// other applications. Cut writes the same file URLs plus a Files-specific
/// marker (`com.files.cut-file-urls`, a JSON array of absolute paths) on the
/// first item. The marker lives on the pasteboard itself, so cut intent works
/// across independent Files windows and is automatically discarded when the
/// pasteboard is replaced or cleared by any application.
enum ClipboardService {
    static let cutType = NSPasteboard.PasteboardType("com.files.cut-file-urls")
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    @discardableResult
    static func write(urls: [URL], cut: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty else {
            pasteboard.clearContents()
            return true
        }
        pasteboard.clearContents()

        let items: [NSPasteboardItem] = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        // Legacy Finder representation (still honoured by many apps).
        if let first = items.first {
            first.setPropertyList(urls.map { $0.path }, forType: legacyFilenamesType)
            if cut, let json = encodedPaths(urls) {
                first.setString(json, forType: cutType)
            }
        }
        return pasteboard.writeObjects(items)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot? {
        guard let urls = fileURLs(from: pasteboard), !urls.isEmpty else { return nil }
        return ClipboardSnapshot(urls: urls, isCut: isCut(urls: urls, on: pasteboard))
    }

    /// File URLs on the pasteboard (absolute, standardized). Drag and drop uses
    /// this as well, since drags are just temporary pasteboards.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !objects.isEmpty {
            return objects.map { $0.standardizedFileURL }
        }
        if let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        return nil
    }

    /// All paths marked as cut on the pasteboard, for dimming list rows.
    static func cutPaths(from pasteboard: NSPasteboard = .general) -> Set<String> {
        guard let json = pasteboard.pasteboardItems?.lazy.compactMap({ $0.string(forType: cutType) }).first,
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    static func isCut(urls: [URL], on pasteboard: NSPasteboard = .general) -> Bool {
        let cutPaths = cutPaths(from: pasteboard)
        guard !cutPaths.isEmpty else { return false }
        let requested = Set(urls.map { $0.standardizedFileURL.path })
        // Only treat the operation as a cut when every URL on the pasteboard is
        // marked; a partially marked/foreign pasteboard is pasted as a copy.
        let pasteboardPaths = Set((fileURLs(from: pasteboard) ?? []).map { $0.standardizedFileURL.path })
        return !requested.isEmpty && requested.isSubset(of: cutPaths) && requested == pasteboardPaths
    }

    /// Re-writes a cut snapshot, dropping items that no longer exist (used
    /// after a partially successful cut/paste).
    static func rewriteCutSnapshotIfNeeded(remaining urls: [URL], to pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else {
            pasteboard.clearContents()
            return
        }
        write(urls: urls, cut: true, to: pasteboard)
    }

    private static func encodedPaths(_ urls: [URL]) -> String? {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard let data = try? JSONEncoder().encode(paths) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
