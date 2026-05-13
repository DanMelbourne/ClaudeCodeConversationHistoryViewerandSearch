import Foundation

class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let path: URL
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval = 1.0
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "com.claudecodecompanion.filewatcher.debounce")

    init(path: URL, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()

        // Ensure the directory exists
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return }

        fileDescriptor = open(path.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.handleChange()
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        self.source = source
        source.resume()
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let source {
            source.cancel()
            self.source = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func handleChange() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        debounceQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
