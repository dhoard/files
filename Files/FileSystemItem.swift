import Foundation

/// A single entry in a directory listing.
///
/// Metadata is read through `URLResourceValues`; filesystem metadata (not just
/// the filename extension) is used for the "kind" column and directory
/// detection. Symbolic links to directories are treated as directories (the
/// listing navigates through them) and flagged so the UI can distinguish them.
struct FileSystemItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let isPackage: Bool
    let fileSize: Int64
    let modificationDate: Date?
    let kind: String

    init(url: URL) {
        self.url = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: DirectoryListing.resourceKeys)
        let resourceName = values?.name ?? url.lastPathComponent
        self.name = resourceName

        var isDirectory = values?.isDirectory ?? false
        var kind = values?.localizedTypeDescription
        if values == nil {
            // Fall back to `stat`-backed attributes when URL resource values
            // fail (for example a dangling symbolic link).
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                isDirectory = isDir.boolValue
            }
            kind = isDirectory ? "Folder" : (url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased())
        }
        let isSymbolicLink = values?.isSymbolicLink ?? false
        // `URLResourceValues.isDirectory` describes the link itself for
        // symbolic links. Directory links are browsable, so follow the link
        // when deciding whether the item is a folder.
        if !isDirectory, isSymbolicLink {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                isDirectory = isDir.boolValue
            }
        }
        let isPackage = values?.isPackage ?? false
        // App bundles and other packages are directories on disk but behave as
        // documents in the listing (open with the default app, not navigate).
        self.isDirectory = isDirectory && !isPackage
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = (values?.isHidden ?? false) || resourceName.hasPrefix(".")
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate
        self.kind = kind ?? (isDirectory ? "Folder" : "Document")
    }
}

/// Column sort keys, matching the table column identifiers.
enum SortKey: String, CaseIterable {
    case name
    case dateModified
    case type
    case size
}

/// Directory enumeration and sorting helpers.
enum DirectoryListing {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .isPackageKey,
        .nameKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .localizedTypeDescriptionKey
    ]

    /// Reads a directory on the calling thread. Call from a background queue
    /// for large directories.
    static func items(in directory: URL, includeHidden: Bool) throws -> [FileSystemItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )
        var result: [FileSystemItem] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let item = FileSystemItem(url: url)
            if !includeHidden && item.isHidden { continue }
            result.append(item)
        }
        return result
    }

    /// Sorts a listing. Folders always sort before files, in both ascending and
    /// descending directions (matching Windows File Explorer). Ties are broken
    /// by name so repeated loads are deterministic.
    static func sort(_ items: [FileSystemItem], by key: SortKey, ascending: Bool) -> [FileSystemItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let result = compare(lhs, rhs, by: key)
            if result == .orderedSame {
                return compare(lhs, rhs, by: .name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare(_ lhs: FileSystemItem, _ rhs: FileSystemItem, by key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .dateModified:
            let left = lhs.modificationDate ?? Date.distantPast
            let right = rhs.modificationDate ?? Date.distantPast
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .type:
            return lhs.kind.localizedStandardCompare(rhs.kind)
        case .size:
            if lhs.fileSize == rhs.fileSize { return .orderedSame }
            return lhs.fileSize < rhs.fileSize ? .orderedAscending : .orderedDescending
        }
    }
}
