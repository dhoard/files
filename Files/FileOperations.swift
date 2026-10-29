import Foundation

enum FileOperationError: LocalizedError {
    case sourceMissing(URL)
    case destinationNotDirectory(URL)
    case sameLocation(URL)
    case insideItself(source: URL, destination: URL)
    case nameExists(URL)
    case invalidName(String)
    case verificationFailed(URL)
    case cancelled

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "“\(url.lastPathComponent)” no longer exists."
        case .destinationNotDirectory(let url):
            return "“\(url.lastPathComponent)” is not a folder."
        case .sameLocation(let url):
            return "“\(url.lastPathComponent)” is already in that folder."
        case .insideItself(let source, let destination):
            return "Cannot copy “\(source.lastPathComponent)” into “\(destination.lastPathComponent)”, because it is inside the source folder."
        case .nameExists(let url):
            return "An item named “\(url.lastPathComponent)” already exists."
        case .invalidName(let name):
            return "“\(name)” is not a valid name. Names cannot be empty or contain “/” or “:”."
        case .verificationFailed(let url):
            return "The copy of “\(url.lastPathComponent)” could not be verified, so the original was kept."
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

enum ConflictResolution: Equatable {
    case skip
    case replace
    case cancel

    var displayName: String {
        switch self {
        case .skip: return "skip"
        case .replace: return "replace"
        case .cancel: return "cancel"
        }
    }
}

struct ConflictInfo {
    let source: URL
    let destination: URL
}

struct OperationProgress {
    let completed: Int
    let total: Int
    let itemName: String
}

struct FileOperationResult {
    var completed: [URL] = []
    var skipped: [URL] = []
    var failures: [(url: URL, error: Error)] = []
    var wasCancelled = false

    var hasProblems: Bool { wasCancelled || !failures.isEmpty || !skipped.isEmpty }

    var summary: String {
        var parts: [String] = []
        if !completed.isEmpty {
            parts.append("\(completed.count) item\(completed.count == 1 ? "" : "s") completed")
        }
        if !skipped.isEmpty {
            parts.append("\(skipped.count) skipped")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) failed")
        }
        if wasCancelled {
            parts.append("cancelled")
        }
        return parts.isEmpty ? "Nothing changed" : parts.joined(separator: ", ")
    }
}

/// Central implementation for every file mutation performed by Files.
///
/// All entry points (menu, keyboard, context menu, drag/drop, clipboard) call
/// this service. The mutating methods are synchronous and throw-free at the
/// batch level: individual item failures are reported in `FileOperationResult`
/// so a batch can partially succeed. Callers run them on a background queue
/// and prompt for conflicts / cancellation through the supplied closures.
///
/// Safety model:
/// - The source is never removed until a cross-volume copy has been verified.
/// - Existing destinations are never overwritten in place; for `replace` the
///   existing item is first moved aside to a temporary sibling, then the new
///   item is moved/copied into place, and only then is the old item deleted.
///   If the transfer fails, the previous item is restored.
/// - Symbolic links are copied as links (never followed), so copy loops are
///   impossible and the link target is preserved.
/// - Copy loops arising from hard-bound directory graphs are additionally
///   refused when copying a folder into itself or a descendant.
final class FileOperations {
    typealias ConflictHandler = (ConflictInfo) -> ConflictResolution
    typealias ProgressHandler = (OperationProgress) -> Void
    typealias CancelCheck = () -> Bool

    static let shared = FileOperations()

    private let fileManager = FileManager.default

    // MARK: - Validation

    func validate(items: [URL], to destinationDirectory: URL) throws {
        try validateDestination(destinationDirectory)
        for item in items {
            try validateTransfer(source: item, into: destinationDirectory)
        }
    }

    /// Validates dropping `items` onto `destination`. Returns `nil` when the
    /// drop is acceptable.
    func dropValidationError(items: [URL], destination: URL) -> FileOperationError? {
        guard !items.isEmpty else { return .sourceMissing(destination) }
        do {
            try validate(items: items, to: destination)
            return nil
        } catch let error as FileOperationError {
            return error
        } catch {
            return .destinationNotDirectory(destination)
        }
    }

    private func validateDestination(_ destinationDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FileOperationError.destinationNotDirectory(destinationDirectory)
        }
    }

    private func validateTransfer(source: URL, into destinationDirectory: URL) throws {
        guard itemExists(at: source) else { throw FileOperationError.sourceMissing(source) }
        try validateDestination(destinationDirectory)
        guard FileManager.default.isReadableFile(atPath: source.path) || isSymbolicLink(at: source) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: source])
        }
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)

        if sameItem(source, destination) {
            throw FileOperationError.sameLocation(source)
        }
        if sameItem(source.deletingLastPathComponent(), destinationDirectory) {
            throw FileOperationError.sameLocation(source)
        }
        if isDirectory(at: source), VolumeInfo.isSameOrDescendant(destinationDirectory, of: source) {
            throw FileOperationError.insideItself(source: source, destination: destinationDirectory)
        }
    }

    // MARK: - Copy

    func copy(
        items: [URL],
        to destinationDirectory: URL,
        conflictHandler: ConflictHandler,
        progress: ProgressHandler? = nil,
        isCancelled: CancelCheck = { false }
    ) -> FileOperationResult {
        transfer(
            items: items,
            to: destinationDirectory,
            move: false,
            conflictHandler: conflictHandler,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    // MARK: - Move

    func move(
        items: [URL],
        to destinationDirectory: URL,
        conflictHandler: ConflictHandler,
        progress: ProgressHandler? = nil,
        isCancelled: CancelCheck = { false }
    ) -> FileOperationResult {
        transfer(
            items: items,
            to: destinationDirectory,
            move: true,
            conflictHandler: conflictHandler,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    private func transfer(
        items: [URL],
        to destinationDirectory: URL,
        move: Bool,
        conflictHandler: ConflictHandler,
        progress: ProgressHandler?,
        isCancelled: CancelCheck
    ) -> FileOperationResult {
        var result = FileOperationResult()

        guard (try? validateDestination(destinationDirectory)) != nil else {
            let error = FileOperationError.destinationNotDirectory(destinationDirectory)
            for item in items { result.failures.append((item, error)) }
            return result
        }

        let total = items.count
        var skippedChildren: [URL] = []

        for (index, source) in items.enumerated() {
            if isCancelled() {
                result.wasCancelled = true
                break
            }
            progress?(OperationProgress(completed: index, total: total, itemName: source.lastPathComponent))
            do {
                try validateTransfer(source: source, into: destinationDirectory)
                let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                let outcome: TransferOutcome
                if move {
                    if VolumeInfo.sameVolume(source.deletingLastPathComponent(), destinationDirectory) {
                        outcome = try moveWithinVolume(
                            from: source,
                            to: destination,
                            conflictHandler: conflictHandler
                        )
                    } else {
                        outcome = try crossVolumeMove(
                            from: source,
                            to: destination,
                            conflictHandler: conflictHandler,
                            isCancelled: isCancelled,
                            skipped: &skippedChildren
                        )
                    }
                } else {
                    outcome = try copyItem(
                        from: source,
                        to: destination,
                        conflictHandler: conflictHandler,
                        isCancelled: isCancelled,
                        skipped: &skippedChildren
                    )
                }

                switch outcome {
                case .transferred(let url):
                    result.completed.append(url)
                case .skipped:
                    result.skipped.append(source)
                }
            } catch {
                if let fileError = error as? FileOperationError, fileError.isCancellation {
                    result.wasCancelled = true
                    break
                }
                result.failures.append((source, error))
            }
        }

        result.skipped.append(contentsOf: skippedChildren)
        progress?(OperationProgress(completed: total, total: total, itemName: ""))
        return result
    }

    // MARK: - Cross-volume move

    /// Copies to the destination, verifies the copy, and only then removes the
    /// source. If verification fails the source is kept and the partial
    /// destination is removed.
    private func crossVolumeMove(
        from source: URL,
        to destination: URL,
        conflictHandler: ConflictHandler,
        isCancelled: CancelCheck,
        skipped: inout [URL]
    ) throws -> TransferOutcome {
        let outcome = try copyItem(
            from: source,
            to: destination,
            conflictHandler: conflictHandler,
            isCancelled: isCancelled,
            skipped: &skipped
        )
        guard case .transferred = outcome else { return outcome }
        guard verifyCopy(from: source, to: destination) else {
            try? fileManager.removeItem(at: destination)
            throw FileOperationError.verificationFailed(source)
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            // The copy is intact and the source remains; report the failure.
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSURLErrorKey: source,
                NSLocalizedDescriptionKey: "The item was copied, but the original could not be removed: \(error.localizedDescription)"
            ])
        }
        return .transferred(destination)
    }

    /// Structural verification used before deleting a cross-volume source:
    /// matching names, matching regular-file byte sizes and matching symbolic
    /// link targets. Checksums are intentionally not computed.
    private func verifyCopy(from source: URL, to destination: URL) -> Bool {
        if isSymbolicLink(at: source) {
            let sourceTarget = try? fileManager.destinationOfSymbolicLink(atPath: source.path)
            let destinationTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination.path)
            return sourceTarget != nil && sourceTarget == destinationTarget
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            let sourceChildren = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
            let destinationChildren = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
            guard Set(sourceChildren) == Set(destinationChildren) else { return false }
            for name in sourceChildren {
                guard verifyCopy(
                    from: source.appendingPathComponent(name),
                    to: destination.appendingPathComponent(name)
                ) else { return false }
            }
            return true
        }
        guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
              let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path) else {
            return false
        }
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value
        let destinationSize = (destinationAttributes[.size] as? NSNumber)?.int64Value
        return sourceSize != nil && sourceSize == destinationSize
    }

    // MARK: - Copy implementation

    private enum TransferOutcome {
        case transferred(URL)
        case skipped
    }

    private func copyItem(
        from source: URL,
        to destination: URL,
        conflictHandler: ConflictHandler,
        isCancelled: CancelCheck,
        skipped: inout [URL]
    ) throws -> TransferOutcome {
        if isCancelled() { throw FileOperationError.cancelled }

        if isSymbolicLink(at: source) {
            return try copySymbolicLink(from: source, to: destination, conflictHandler: conflictHandler)
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw FileOperationError.sourceMissing(source)
        }
        if isDir.boolValue {
            return try copyDirectory(
                from: source,
                to: destination,
                conflictHandler: conflictHandler,
                isCancelled: isCancelled,
                skipped: &skipped
            )
        }
        return try copyRegularFile(from: source, to: destination, conflictHandler: conflictHandler)
    }

    private func copyRegularFile(
        from source: URL,
        to destination: URL,
        conflictHandler: ConflictHandler
    ) throws -> TransferOutcome {
        var backup: URL?
        if itemExists(at: destination) {
            switch conflictHandler(ConflictInfo(source: source, destination: destination)) {
            case .skip:
                return .skipped
            case .cancel:
                throw FileOperationError.cancelled
            case .replace:
                backup = try stageAside(destination)
            }
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            cleanupFailedTransfer(destination: destination, backup: backup)
            throw error
        }
        if let backup { removeBackup(backup) }
        return .transferred(destination)
    }

    private func copySymbolicLink(
        from source: URL,
        to destination: URL,
        conflictHandler: ConflictHandler
    ) throws -> TransferOutcome {
        let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        var backup: URL?
        if itemExists(at: destination) {
            switch conflictHandler(ConflictInfo(source: source, destination: destination)) {
            case .skip:
                return .skipped
            case .cancel:
                throw FileOperationError.cancelled
            case .replace:
                backup = try stageAside(destination)
            }
        }
        do {
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } catch {
            cleanupFailedTransfer(destination: destination, backup: backup)
            throw error
        }
        if let backup { removeBackup(backup) }
        return .transferred(destination)
    }

    private func copyDirectory(
        from source: URL,
        to destination: URL,
        conflictHandler: ConflictHandler,
        isCancelled: CancelCheck,
        skipped: inout [URL]
    ) throws -> TransferOutcome {
        var backup: URL?
        if itemExists(at: destination) {
            switch conflictHandler(ConflictInfo(source: source, destination: destination)) {
            case .skip:
                return .skipped
            case .cancel:
                throw FileOperationError.cancelled
            case .replace:
                backup = try stageAside(destination)
            }
        }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: nil)
            if let permissions = try? fileManager.attributesOfItem(atPath: source.path)[.posixPermissions] {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            }
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children {
                if isCancelled() { throw FileOperationError.cancelled }
                let childDestination = destination.appendingPathComponent(child.lastPathComponent)
                let outcome = try copyItem(
                    from: child,
                    to: childDestination,
                    conflictHandler: conflictHandler,
                    isCancelled: isCancelled,
                    skipped: &skipped
                )
                if case .skipped = outcome {
                    skipped.append(child)
                }
            }
        } catch {
            cleanupFailedTransfer(destination: destination, backup: backup)
            throw error
        }
        if let backup { removeBackup(backup) }
        return .transferred(destination)
    }

    // MARK: - Move implementation (same volume)

    private func moveWithinVolume(
        from source: URL,
        to destination: URL,
        conflictHandler: ConflictHandler
    ) throws -> TransferOutcome {
        var backup: URL?
        if itemExists(at: destination) {
            if sameItem(source, destination) {
                throw FileOperationError.sameLocation(source)
            }
            switch conflictHandler(ConflictInfo(source: source, destination: destination)) {
            case .skip:
                return .skipped
            case .cancel:
                throw FileOperationError.cancelled
            case .replace:
                backup = try stageAside(destination)
            }
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            cleanupFailedTransfer(destination: destination, backup: backup)
            throw error
        }
        if let backup { removeBackup(backup) }
        return .transferred(destination)
    }

    // MARK: - Replacement staging

    private func stageAside(_ destination: URL) throws -> URL {
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".files-replace-\(UUID().uuidString)")
        try fileManager.moveItem(at: destination, to: backup)
        return backup
    }

    private func removeBackup(_ backup: URL) {
        try? fileManager.removeItem(at: backup)
    }

    private func cleanupFailedTransfer(destination: URL, backup: URL?) {
        // Never leave a half-written new item behind. If the original was
        // staged aside, restore it; otherwise remove only what this operation
        // created.
        if let backup {
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: backup, to: destination)
        } else {
            try? fileManager.removeItem(at: destination)
        }
    }

    // MARK: - Rename / create / trash

    /// Renames an item in place. Case-only renames on case-insensitive volumes
    /// are performed through a temporary name.
    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":") else {
            throw FileOperationError.invalidName(newName)
        }
        guard itemExists(at: url) else { throw FileOperationError.sourceMissing(url) }
        let parent = url.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(trimmed)
        if trimmed == url.lastPathComponent { return url }
        if sameItem(url, destination) {
            // Case-only rename (or a path that only differs by case).
            let temporary = parent.appendingPathComponent(".files-rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: url, to: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.moveItem(at: temporary, to: url)
                throw error
            }
            return destination
        }
        guard !itemExists(at: destination) else { throw FileOperationError.nameExists(destination) }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// Creates a uniquely named folder and returns it.
    @discardableResult
    func createFolder(in directory: URL, preferredName: String = "untitled folder") throws -> URL {
        try validateDestination(directory)
        var name = preferredName
        var counter = 2
        while itemExists(at: directory.appendingPathComponent(name)) {
            name = "\(preferredName) \(counter)"
            counter += 1
        }
        let url = directory.appendingPathComponent(name)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
        return url
    }

    /// Moves items to the user's Trash. Permanent deletion is never performed.
    func moveToTrash(_ items: [URL]) -> FileOperationResult {
        var result = FileOperationResult()
        for url in items {
            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resulting)
                result.completed.append((resulting as URL?) ?? url)
            } catch {
                result.failures.append((url, error))
            }
        }
        return result
    }

    // MARK: - Identity helpers

    func itemExists(at url: URL) -> Bool {
        if (try? fileManager.attributesOfItem(atPath: url.path)) != nil { return true }
        // `attributesOfItem` follows symlinks, so dangling links report false.
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else { return false }
        return true
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Filesystem identity comparison using `.fileResourceIdentifier`, with a
    /// case-aware path comparison as a fallback.
    func sameItem(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let left = VolumeInfo.resourceValues(for: a, keys: keys)?.fileResourceIdentifier,
           let right = VolumeInfo.resourceValues(for: b, keys: keys)?.fileResourceIdentifier,
           left.isEqual(right) {
            return true
        }
        return VolumeInfo.comparisonKey(a) == VolumeInfo.comparisonKey(b)
    }
}
