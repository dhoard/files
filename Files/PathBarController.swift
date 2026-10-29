import AppKit

/// Always-editable POSIX path field.
///
/// The field shows the current lexical absolute path at all times. Return
/// validates through `onSubmit`; a rejected path leaves editing active so the
/// user can correct it, and the window controller displays the error. Escape
/// restores the current path. Tab completes directory names on a best-effort
/// basis (single match, or the common prefix of multiple matches).
final class PathBarController: NSObject, NSTextFieldDelegate {
    let textField: NSTextField

    /// Called with the entered text. Return `true` when navigation was
    /// accepted (editing ends and focus moves to the file list).
    var onSubmit: ((String) -> Bool)?
    var onCancel: (() -> Void)?

    private var currentPath = ""

    override init() {
        textField = NSTextField(frame: .zero)
        super.init()
        configure()
    }

    private func configure() {
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = .systemFont(ofSize: 12)
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingHead
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.placeholderString = "Enter a folder path"
        textField.delegate = self
        textField.target = self
        textField.action = #selector(submit(_:))
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.toolTip = "Type an absolute path (or ~/path) and press Return"
    }

    func setCurrentPath(_ path: String) {
        currentPath = path
        if textField.currentEditor() == nil {
            textField.stringValue = path
            textField.textColor = .labelColor
        }
    }

    func focus() {
        guard let window = textField.window else { return }
        window.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    @objc private func submit(_ sender: Any?) {
        _ = handleSubmit()
    }

    @discardableResult
    private func handleSubmit() -> Bool {
        guard let onSubmit else { return false }
        if onSubmit(textField.stringValue) {
            // The window controller updates `currentPath` during navigation;
            // show the standardized form rather than the typed text.
            textField.stringValue = currentPath
            textField.abortEditing()
            return true
        }
        // Keep the entered text selected so it can be corrected.
        textField.currentEditor()?.selectAll(nil)
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleSubmit()
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField.stringValue = currentPath
            textField.abortEditing()
            textField.textColor = .labelColor
            onCancel?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if let completion = completion(for: textField.stringValue) {
                textField.stringValue = completion
                textField.currentEditor()?.moveToEndOfLine(nil)
            }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // If editing ended without a successful submit (focus loss), show the
        // actual current path again.
        if textField.stringValue != currentPath {
            let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
            if movement == NSReturnTextMovement {
                // A Return that failed validation; the controller owns the
                // inline error display, restore the field to the real path.
                textField.stringValue = currentPath
            } else {
                textField.stringValue = currentPath
            }
        }
    }

    /// Best-effort shell-style completion. Returns an absolute path.
    func completion(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let endsWithSlash = expanded.hasSuffix("/")
        let directoryPath: String
        let partial: String
        if endsWithSlash {
            directoryPath = String(expanded.dropLast())
            partial = ""
        } else {
            directoryPath = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        let searchDirectory = directoryPath.isEmpty ? "/" : directoryPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: searchDirectory) else {
            return nil
        }
        let matches = names
            .filter { partial.isEmpty ? true : $0.lowercased().hasPrefix(partial.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = matches.first else { return nil }

        if matches.count == 1 {
            var completed = (searchDirectory as NSString).appendingPathComponent(first)
            var isDirectory: ObjCBool = false
            let isPackage = (try? URL(fileURLWithPath: completed).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            if FileManager.default.fileExists(atPath: completed, isDirectory: &isDirectory),
               isDirectory.boolValue,
               !isPackage {
                completed += "/"
            }
            return completed
        }

        // Multiple matches: extend to the longest common prefix, but only when
        // that actually adds characters.
        guard let prefix = commonPrefix(of: matches), prefix.count > partial.count else {
            return nil
        }
        return (searchDirectory as NSString).appendingPathComponent(prefix)
    }

    private func commonPrefix(of names: [String]) -> String? {
        guard var prefix = names.first else { return nil }
        for name in names.dropFirst() {
            while !prefix.isEmpty && !name.lowercased().hasPrefix(prefix.lowercased()) {
                prefix = String(prefix.dropLast())
            }
            if prefix.isEmpty { return nil }
        }
        return prefix
    }
}
