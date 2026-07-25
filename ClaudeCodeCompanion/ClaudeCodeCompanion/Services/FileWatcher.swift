import CoreServices
import Foundation

/// Recursively observes a conversation-source directory and coalesces file activity.
///
/// Claude Code creates and appends transcripts inside project and subagent
/// directories. A vnode source attached only to the top-level directory misses
/// writes below an existing child directory, so this uses FSEvents instead.
final class FileWatcher {
    private var eventStream: FSEventStreamRef?
    private let path: URL
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval = 1.0
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "com.claudecodecompanion.filewatcher.debounce")
    private let eventQueue = DispatchQueue(label: "com.claudecodecompanion.filewatcher.events", qos: .utility)

    init(path: URL, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()

        guard FileManager.default.fileExists(atPath: path.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            [path.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        ) else {
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            stop()
            return
        }
    }

    func stop() {
        debounceQueue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
        }

        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private static let handleEvents: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().scheduleChange()
    }

    private func scheduleChange() {
        debounceQueue.async { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.onChange()
            }
            self.debounceWorkItem = workItem
            self.debounceQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
        }
    }
}
