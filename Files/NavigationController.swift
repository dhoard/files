import Foundation

/// Back/forward history for one explorer window.
///
/// The history holds lexical (standardized but not symlink-resolved) URLs.
/// Navigating to the current directory again does not create a duplicate
/// entry, which keeps refresh/reveal operations from polluting history.
struct NavigationHistory {
    private(set) var entries: [URL]
    private(set) var index: Int

    init(initialURL: URL) {
        let url = initialURL.standardizedFileURL
        self.entries = [url]
        self.index = 0
    }

    var current: URL { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }
    var backURL: URL? { canGoBack ? entries[index - 1] : nil }
    var forwardURL: URL? { canGoForward ? entries[index + 1] : nil }

    /// Adds a new location, discarding any forward history.
    /// Returns `false` when the location is the current one.
    @discardableResult
    mutating func navigate(to url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard target.path != current.path else { return false }
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(target)
        index = entries.count - 1
        return true
    }

    /// Changes the current location without adding history (refresh/reveal).
    mutating func replaceCurrent(with url: URL) {
        entries[index] = url.standardizedFileURL
    }

    mutating func goBack() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func goForward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}

enum PathError: LocalizedError, Equatable {
    case empty
    case notAbsolute(String)
    case notFound(String)
    case notDirectory(String)
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a folder path."
        case .notAbsolute(let path):
            return "“\(path)” is not an absolute path. Paths must begin with “/” or “~”."
        case .notFound(let path):
            return "The folder “\(path)” does not exist."
        case .notDirectory(let path):
            return "“\(path)” is not a folder."
        case .notReadable(let path):
            return "You do not have permission to open “\(path)”."
        }
    }
}

/// Turns user-typed location text into a validated directory URL.
///
/// Paths are expanded (`~` and `~user`) and standardized lexically (`.`,
/// `..`, duplicate slashes). Symbolic links are intentionally *not* resolved:
/// the location bar shows the lexical path the user navigated to.
enum PathResolver {
    static func expand(_ input: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        if text.hasPrefix("~") {
            if text == "~" {
                text = homeDirectory.path
            } else if text.hasPrefix("~/") {
                text = homeDirectory.path + String(text.dropFirst())
            } else {
                text = (text as NSString).expandingTildeInPath
            }
        }
        return (text as NSString).standardizingPath
    }

    static func directoryURL(from input: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let expanded = expand(input, homeDirectory: homeDirectory)
        guard !expanded.isEmpty else { throw PathError.empty }
        guard expanded.hasPrefix("/") else { throw PathError.notAbsolute(expanded) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            throw PathError.notFound(expanded)
        }
        guard isDirectory.boolValue else {
            throw PathError.notDirectory(expanded)
        }
        guard FileManager.default.isReadableFile(atPath: expanded) else {
            throw PathError.notReadable(expanded)
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}

/// Filesystem identity helpers shared by navigation, drag/drop and file
/// operations. Volume identity is derived from filesystem metadata rather
/// than path text.
enum VolumeInfo {
    static func resourceValues(for url: URL, keys: Set<URLResourceKey>) -> URLResourceValues? {
        if let values = try? url.resourceValues(forKeys: keys) {
            return values
        }
        // Non-existent paths (destination candidates) still need volume
        // information; walk up to the nearest existing ancestor.
        var ancestor = url.deletingLastPathComponent()
        var guardCounter = 0
        while ancestor.path != "/" && !FileManager.default.fileExists(atPath: ancestor.path) && guardCounter < 256 {
            ancestor = ancestor.deletingLastPathComponent()
            guardCounter += 1
        }
        return try? ancestor.resourceValues(forKeys: keys)
    }

    static func identifier(of url: URL) -> NSObject? {
        guard let value = resourceValues(for: url, keys: [.volumeIdentifierKey])?.volumeIdentifier else {
            return nil
        }
        return value as? NSObject
    }

    static func isCaseInsensitive(_ url: URL) -> Bool {
        let supportsCaseSensitive = resourceValues(
            for: url,
            keys: [.volumeSupportsCaseSensitiveNamesKey]
        )?.volumeSupportsCaseSensitiveNames ?? true
        return !supportsCaseSensitive
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        if let left = identifier(of: a), let right = identifier(of: b) {
            return left.isEqual(right)
        }
        // Fallback for volumes/filesystems without a URL volume identifier:
        // the filesystem device number reported by FileManager.
        if let left = systemNumber(a), let right = systemNumber(b) {
            return left == right
        }
        return false
    }

    private static func systemNumber(_ url: URL) -> Int? {
        var existing = url
        var guardCounter = 0
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/", guardCounter < 256 {
            existing = existing.deletingLastPathComponent()
            guardCounter += 1
        }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: existing.path) else {
            return nil
        }
        return (attributes[.systemNumber] as? NSNumber)?.intValue
    }

    /// A path comparison key that resolves symbolic links (for the existing
    /// part of the path) and lowercases on case-insensitive volumes.
    static func comparisonKey(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return isCaseInsensitive(url) ? resolved.lowercased() : resolved
    }

    /// True when `candidate` is the same path as, or located inside, `ancestor`.
    /// Uses physical (symlink-resolved) paths so links cannot escape the check.
    static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = components(of: comparisonKey(candidate))
        let ancestorComponents = components(of: comparisonKey(ancestor))
        guard candidateComponents.count >= ancestorComponents.count else { return false }
        return Array(candidateComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    private static func components(of path: String) -> [String] {
        // URL(fileURLWithPath:).pathComponents handles the leading "/" and
        // duplicate separators consistently.
        URL(fileURLWithPath: path).pathComponents
    }
}
