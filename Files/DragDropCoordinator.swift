import AppKit

/// Shared drag/drop policy.
///
/// Dragging follows Windows Explorer conventions as closely as AppKit allows:
/// same volume moves, cross-volume copies, Option forces copy and Command
/// forces move. The drag source's advertised operation mask always wins: an
/// operation the source does not offer is never performed.
enum DragDropCoordinator {
    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setPropertyList([url.path], forType: ClipboardService.legacyFilenamesType)
        return item
    }

    static func fileURLs(from info: NSDraggingInfo) -> [URL] {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls.map { $0.standardizedFileURL }
    }

    /// Returns the operation to perform, or `[]` when the drop must be
    /// rejected or no allowed operation exists.
    static func proposedOperation(for urls: [URL], destination: URL, info: NSDraggingInfo) -> NSDragOperation {
        guard !urls.isEmpty else { return [] }
        if FileOperations.shared.dropValidationError(items: urls, destination: destination) != nil {
            return []
        }

        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let sameVolume = urls.allSatisfy { VolumeInfo.sameVolume($0, destination) }
        return desiredOperation(
            modifierFlags: modifiers,
            sameVolume: sameVolume,
            allowed: info.draggingSourceOperationMask
        )
    }

    /// Explorer-style operation policy, factored out for testing:
    /// Option requests copy, Command requests move, otherwise same-volume
    /// drags move and cross-volume drags copy. Operations the source does not
    /// advertise are replaced by the other operation when possible, never
    /// performed unsupported.
    static func desiredOperation(
        modifierFlags: NSEvent.ModifierFlags,
        sameVolume: Bool,
        allowed: NSDragOperation
    ) -> NSDragOperation {
        var desired: NSDragOperation
        if modifierFlags.contains(.option) {
            desired = .copy
        } else if modifierFlags.contains(.command) {
            desired = .move
        } else {
            desired = sameVolume ? .move : .copy
        }

        let allowsCopy = allowed.contains(.copy) || allowed.contains(.generic)
        let allowsMove = allowed.contains(.move) || allowed.contains(.generic)

        if desired == .copy && !allowsCopy {
            return allowsMove ? .move : []
        }
        if desired == .move && !allowsMove {
            return allowsCopy ? .copy : []
        }
        return desired
    }
}
