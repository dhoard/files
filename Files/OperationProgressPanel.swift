import AppKit

/// Thread-safe cancellation flag shared by the progress panel (main thread)
/// and the operation (background queue).
final class CancellationFlag {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Small non-modal progress panel shown for long copy/move operations. It is
/// displayed only if the operation takes longer than a short delay, so quick
/// single-item operations do not flash a panel.
final class OperationProgressPanel: NSObject {
    private let panel: NSPanel
    private let statusLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private let cancelButton: NSButton
    private let flag = CancellationFlag()

    private weak var parentWindow: NSWindow?
    private var latest: OperationProgress?
    private var isVisible = false
    private var isFinished = false
    private var showScheduled = false

    var isCancelled: Bool { flag.isCancelled }

    init(title: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        statusLabel = NSTextField(labelWithString: "Preparing…")
        progressBar = NSProgressIndicator()
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        super.init()

        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        panel.contentView = content

        statusLabel.frame = NSRect(x: 20, y: 80, width: 420, height: 18)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 12)

        progressBar.frame = NSRect(x: 20, y: 52, width: 420, height: 14)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0

        cancelButton.frame = NSRect(x: 340, y: 14, width: 100, height: 28)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        content.addSubview(statusLabel)
        content.addSubview(progressBar)
        content.addSubview(cancelButton)
    }

    func present(relativeTo parent: NSWindow?) {
        parentWindow = parent
        if let parent {
            let size = panel.frame.size
            let origin = NSPoint(
                x: parent.frame.midX - size.width / 2,
                y: parent.frame.midY - size.height / 2
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        showScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.showScheduled, !self.isFinished else { return }
            self.show()
        }
    }

    private func show() {
        guard !isVisible, !isFinished else { return }
        isVisible = true
        if let parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        if let latest {
            render(latest)
        }
    }

    func update(_ progress: OperationProgress) {
        latest = progress
        guard isVisible else { return }
        render(progress)
    }

    private func render(_ progress: OperationProgress) {
        if progress.total > 0 {
            progressBar.doubleValue = Double(progress.completed) / Double(progress.total)
        }
        if progress.itemName.isEmpty {
            statusLabel.stringValue = "Finishing…"
        } else {
            statusLabel.stringValue = "“\(progress.itemName)” — \(progress.completed + 1) of \(progress.total)"
        }
    }

    func finish() {
        isFinished = true
        showScheduled = false
        guard isVisible else { return }
        isVisible = false
        if let parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    @objc private func cancel(_ sender: Any?) {
        guard !flag.isCancelled else { return }
        flag.cancel()
        cancelButton.isEnabled = false
        statusLabel.stringValue = "Cancelling…"
    }
}
