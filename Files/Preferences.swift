import Foundation

/// Names of the `UserDefaults` keys used by Files.
enum PreferenceKey {
    static let prefix = "files."
    static let showHiddenFiles = prefix + "showHiddenFiles"
    static let sortKey = prefix + "sortKey"
    static let sortAscending = prefix + "sortAscending"
    static let windowFrame = prefix + "windowFrame"
    static let splitFraction = prefix + "splitFraction"
    static let columnWidthPrefix = prefix + "columnWidth."
}

/// Persisted, application-wide preferences.
///
/// Only values that should survive relaunches live here. Per-window runtime
/// state (history, selection, expansion) is kept by the individual window
/// controllers and is deliberately not persisted.
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var showHiddenFiles: Bool {
        get { defaults.object(forKey: PreferenceKey.showHiddenFiles) as? Bool ?? false }
        set { defaults.set(newValue, forKey: PreferenceKey.showHiddenFiles) }
    }

    var sortKey: String? {
        get { defaults.string(forKey: PreferenceKey.sortKey) }
        set { defaults.set(newValue, forKey: PreferenceKey.sortKey) }
    }

    var sortAscending: Bool {
        get { defaults.object(forKey: PreferenceKey.sortAscending) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.sortAscending) }
    }

    /// Fraction of the window width occupied by the directory tree (0.15 - 0.75).
    var splitFraction: Double? {
        get {
            guard let value = defaults.object(forKey: PreferenceKey.splitFraction) as? Double else { return nil }
            return min(max(value, 0.15), 0.75)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: PreferenceKey.splitFraction)
                return
            }
            defaults.set(min(max(newValue, 0.15), 0.75), forKey: PreferenceKey.splitFraction)
        }
    }

    var windowFrame: NSRect? {
        get {
            guard let string = defaults.string(forKey: PreferenceKey.windowFrame) else { return nil }
            let rect = NSRectFromString(string)
            guard rect.width >= 400, rect.height >= 300 else { return nil }
            return rect
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: PreferenceKey.windowFrame)
                return
            }
            defaults.set(NSStringFromRect(newValue), forKey: PreferenceKey.windowFrame)
        }
    }

    func columnWidth(for identifier: String) -> CGFloat? {
        guard let value = defaults.object(forKey: PreferenceKey.columnWidthPrefix + identifier) as? Double else { return nil }
        return CGFloat(value)
    }

    func setColumnWidth(_ width: CGFloat, for identifier: String) {
        defaults.set(Double(width), forKey: PreferenceKey.columnWidthPrefix + identifier)
    }
}
