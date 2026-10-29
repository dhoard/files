import Foundation
import CoreServices

/// Watches a set of directories with FSEvents and reports coalesced batches of
/// changed paths on the main thread.
///
/// The window controller watches only the currently open directory plus the
/// directories currently expanded in the tree; the entire filesystem is never
/// watched or rescanned. Event bursts are debounced (250 ms) so bulk changes
/// result in a single UI refresh.
final class DirectoryMonitor {
    private let queue = DispatchQueue(label: "com.files.directory-monitor", qos: .utility)
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []

    private var pendingChangedPaths = Set<String>()
    private var flushWorkItem: DispatchWorkItem?

    /// Called on the main thread with the changed paths.
    var onChange: (([String]) -> Void)?

    deinit {
        stop()
    }

    /// Replaces the watched path set, restarting the stream only when the set
    /// actually changed.
    func setWatchedPaths(_ paths: [String]) {
        let unique = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard unique != watchedPaths else { return }
        watchedPaths = unique
        restartStream()
    }

    func stop() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        DispatchQueue.main.async { [weak self] in
            self?.pendingChangedPaths.removeAll()
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func restartStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !watchedPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let monitor = Unmanaged<DirectoryMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            monitor.receive(paths: Array(paths.prefix(numEvents)))
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            FSEventStreamCreateFlags(flags)
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            return
        }
        stream = newStream
    }

    private func receive(paths: [String]) {
        guard !paths.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingChangedPaths.formUnion(paths)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func flush() {
        flushWorkItem = nil
        let paths = pendingChangedPaths
        pendingChangedPaths.removeAll()
        guard !paths.isEmpty else { return }
        onChange?(Array(paths))
    }
}
