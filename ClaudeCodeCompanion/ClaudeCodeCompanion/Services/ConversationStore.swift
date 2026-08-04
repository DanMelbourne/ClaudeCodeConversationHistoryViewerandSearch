import Foundation

@MainActor
@Observable
class ConversationStore {
    var projects: [Project] = []
    var isIndexing = false
    var indexingProgress: (current: Int, total: Int) = (0, 0)

    let db = DatabaseManager()
    private let parser = JSONLParser()
    private let claudeProjectsPath: URL

    init() {
        claudeProjectsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    // MARK: - Full index

    func performFullIndex() async throws {
        isIndexing = true
        defer { isIndexing = false }

        try await db.open()
        try await db.createSchema()

        let projectsPath = claudeProjectsPath
        let jsonlFiles = await Task.detached(priority: .utility) {
            Self.collectJSONLFiles(under: projectsPath)
        }.value
        indexingProgress = (0, jsonlFiles.count)

        // One ledger read for the whole pass instead of a query per file.
        let knownStates = await db.indexedFileStates()

        // Parsing is CPU-bound and independent per file, so files are parsed a
        // window at a time across cores; the database stays a single writer.
        let window = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        var completed = 0

        for chunk in stride(from: 0, to: jsonlFiles.count, by: window) {
            let slice = Array(jsonlFiles[chunk..<min(chunk + window, jsonlFiles.count)])
            let parser = self.parser

            let parsed = await withTaskGroup(of: PendingIndex?.self) { group in
                for file in slice {
                    let state = knownStates[file.path]
                    let projectPath = deriveProjectPath(from: file)
                    group.addTask(priority: .utility) {
                        await Self.parse(file: file, projectPath: projectPath, knownState: state, parser: parser)
                    }
                }
                var results: [PendingIndex] = []
                for await result in group {
                    if let result { results.append(result) }
                }
                return results
            }

            for pending in parsed {
                try await db.indexMessages(
                    pending.messages,
                    filePath: pending.file.path,
                    modificationDate: pending.modificationDate,
                    projectPath: pending.projectPath,
                    isSubagent: pending.isSubagent,
                    agent: .claude,
                    replaceExisting: pending.replaceExisting,
                    bytesIndexed: pending.bytesConsumed
                )
            }

            completed += slice.count
            indexingProgress = (completed, jsonlFiles.count)
        }

        try await indexOtherAgents()
        try await loadProjects()
    }

    // MARK: - Other agents

    /// Index Codex and Cursor history when those agents are switched on, and
    /// purge an agent's rows as soon as it is switched off.
    func indexOtherAgents() async throws {
        try await db.open()
        try await db.createSchema()

        if AgentKind.isEnabled(.codex) {
            try await indexCodexSessions()
        } else {
            try await db.deleteMessages(agent: .codex)
        }

        if AgentKind.isEnabled(.cursor) {
            try await indexCursorConversations()
        } else {
            try await db.deleteMessages(agent: .cursor)
        }
    }

    /// Index every Codex rollout that changed since the last pass.
    ///
    /// Rollouts are streamed in batches, so even a multi-gigabyte session is
    /// indexed in full — search covers every message — without ever holding
    /// the whole transcript in memory.
    func indexCodexSessions(root: URL = CodexHistoryProvider.rootDirectory) async throws {
        let files = await Task.detached(priority: .utility) {
            CodexHistoryProvider.rolloutFiles(under: root)
        }.value
        let knownStates = await db.indexedFileStates()

        for file in files {
            guard let attributes = await Task.detached(priority: .utility, operation: {
                Self.regularFileAttributes(at: file)
            }).value else { continue }
            let modDate = attributes.modificationDate

            var resumeOffset = 0
            if let state = knownStates[file.path] {
                guard modDate > state.modificationDate else { continue }
                // Rollouts are append-only; read only what has been added since.
                if state.bytesIndexed > 0, attributes.size >= state.bytesIndexed {
                    resumeOffset = state.bytesIndexed
                }
            }

            var isFirstBatch = true
            for await batch in Self.codexBatches(for: file, fromByteOffset: resumeOffset) {
                defer { batch.ack() }
                guard let projectPath = batch.projectPath else { continue }
                try await db.indexMessages(
                    batch.messages,
                    filePath: file.path,
                    modificationDate: modDate,
                    projectPath: projectPath,
                    isSubagent: false,
                    agent: .codex,
                    replaceExisting: isFirstBatch && resumeOffset == 0,
                    bytesIndexed: batch.bytesConsumed
                )
                isFirstBatch = false
            }
        }
    }

    /// One batch of a streamed rollout. `ack` releases the reader for the next
    /// batch and must be called exactly once.
    struct CodexBatch: @unchecked Sendable {
        let messages: [ConversationMessage]
        let projectPath: String?
        /// Byte offset to resume from if indexing stops after this batch.
        let bytesConsumed: Int
        let ack: () -> Void
    }

    /// Batches of a Codex rollout, produced on a background thread that waits
    /// for each batch to be indexed before reading further. That backpressure
    /// is what keeps a gigabyte-scale rollout at two batches of memory.
    private nonisolated static func codexBatches(
        for file: URL,
        fromByteOffset offset: Int = 0
    ) -> AsyncStream<CodexBatch> {
        AsyncStream { continuation in
            let indexed = DispatchSemaphore(value: 0)
            var finished = false
            let finishedLock = NSLock()

            continuation.onTermination = { _ in
                // Release the producer if the consumer stopped early.
                finishedLock.lock()
                finished = true
                finishedLock.unlock()
                indexed.signal()
            }

            Task.detached(priority: .utility) {
                _ = CodexHistoryProvider.stream(at: file, fromByteOffset: offset) { batch, info, consumed in
                    finishedLock.lock()
                    let stop = finished
                    finishedLock.unlock()
                    guard !stop else { return }

                    continuation.yield(
                        CodexBatch(
                            messages: batch,
                            projectPath: info.projectPath,
                            bytesConsumed: consumed,
                            ack: { indexed.signal() }
                        )
                    )
                    indexed.wait()
                }
                continuation.finish()
            }
        }
    }

    /// Index every Cursor conversation that changed since the last pass.
    func indexCursorConversations(databaseURL: URL = CursorHistoryProvider.databaseURL) async throws {
        guard CursorHistoryProvider.isAvailable(databaseURL: databaseURL) else { return }

        let conversations = await Task.detached(priority: .utility) {
            CursorHistoryProvider.conversations(databaseURL: databaseURL)
        }.value
        let knownDates = await db.indexedFileModificationDates()

        for conversation in conversations {
            let modDate = conversation.lastModified
            if let indexed = knownDates[conversation.indexKey], modDate <= indexed { continue }

            let messages = await Task.detached(priority: .utility) {
                CursorHistoryProvider.messages(for: conversation, databaseURL: databaseURL)
            }.value
            guard !messages.isEmpty else { continue }

            try await db.indexMessages(
                messages,
                filePath: conversation.indexKey,
                modificationDate: modDate,
                projectPath: conversation.projectPath,
                isSubagent: false,
                agent: .cursor
            )
        }
    }

    /// One file's parse result, waiting for its turn at the single DB writer.
    private struct PendingIndex: Sendable {
        let file: URL
        let projectPath: String
        let isSubagent: Bool
        let modificationDate: Date
        let messages: [ConversationMessage]
        let bytesConsumed: Int
        let replaceExisting: Bool
    }

    /// Decide whether a file needs work and parse whatever is new, off the main
    /// actor. Returns nil when the file is unchanged.
    private nonisolated static func parse(
        file: URL,
        projectPath: String,
        knownState: DatabaseManager.IndexedFileState?,
        parser: JSONLParser
    ) async -> PendingIndex? {
        guard let attributes = regularFileAttributes(at: file) else { return nil }

        var resumeOffset = 0
        if let knownState {
            guard attributes.modificationDate > knownState.modificationDate else { return nil }
            if knownState.bytesIndexed > 0, attributes.size >= knownState.bytesIndexed {
                resumeOffset = knownState.bytesIndexed
            }
        }

        guard let result = try? parser.parseFile(
            at: file,
            projectPath: projectPath,
            fromByteOffset: resumeOffset
        ), !result.messages.isEmpty else { return nil }

        return PendingIndex(
            file: file,
            projectPath: projectPath,
            isSubagent: JSONLParser.isSubagentPath(file),
            modificationDate: attributes.modificationDate,
            messages: result.messages,
            bytesConsumed: result.bytesConsumed,
            replaceExisting: resumeOffset == 0
        )
    }

    // MARK: - Single file index

    /// - knownState: what the index already recorded for this file, when the
    ///   caller has read the whole ledger up front.
    func indexFile(at url: URL, knownState: DatabaseManager.IndexedFileState? = nil) async throws {
        guard let attributes = await Task.detached(priority: .utility, operation: {
            Self.regularFileAttributes(at: url)
        }).value else { return }
        let modDate = attributes.modificationDate

        var resumeOffset = 0
        if let knownState {
            guard modDate > knownState.modificationDate else { return }
            // Resume only while the file has grown: a rewritten or truncated
            // transcript must be read again from the start.
            if knownState.bytesIndexed > 0, attributes.size >= knownState.bytesIndexed {
                resumeOffset = knownState.bytesIndexed
            }
        } else {
            guard await db.needsReindex(path: url.path, modificationDate: modDate) else { return }
        }

        let projectPath = deriveProjectPath(from: url)
        let isSubagent = JSONLParser.isSubagentPath(url)

        let result = try await parser.parseFile(at: url, projectPath: projectPath, fromByteOffset: resumeOffset)
        guard !result.messages.isEmpty else { return }

        try await db.indexMessages(
            result.messages,
            filePath: url.path,
            modificationDate: modDate,
            projectPath: projectPath,
            isSubagent: isSubagent,
            agent: .claude,
            replaceExisting: resumeOffset == 0,
            bytesIndexed: result.bytesConsumed
        )
    }

    // MARK: - Index external directory

    /// Index all JSONL files under an arbitrary directory (e.g. a remote Mac's .claude/projects).
    func indexDirectory(_ directory: URL) async throws {
        try await db.open()
        try await db.createSchema()

        let jsonlFiles = await Task.detached(priority: .utility) {
            Self.collectJSONLFiles(under: directory)
        }.value
        for file in jsonlFiles {
            try await indexFile(at: file)
        }
    }

    // MARK: - Load from database

    func loadProjects() async throws {
        projects = try await db.allProjects()
    }

    func loadSessions(for project: Project) async throws -> [ConversationSession] {
        try await db.sessionsForProject(projectPath: project.id)
    }

    /// Projects that hold history from agents other than Claude Code.
    /// Read from the index because Codex and Cursor have no per-project folder.
    func projects(agents: Set<AgentKind>) async throws -> [Project] {
        guard !agents.isEmpty else { return [] }
        return try await db.allProjects(agents: agents)
    }

    /// Sessions belonging to the given project folders for the given agents.
    func sessions(projectPaths: [String], agents: Set<AgentKind>) async throws -> [ConversationSession] {
        var sessions: [ConversationSession] = []
        var seen = Set<String>()
        for path in projectPaths {
            let found = try await db.sessionsForProject(projectPath: path, includeWorktrees: true)
            for session in found where agents.contains(session.agent) && seen.insert(session.id).inserted {
                sessions.append(session)
            }
        }

        // Cursor names its conversations; show that name instead of leaving the
        // row identified only by an opaque composer id.
        if sessions.contains(where: { $0.agent == .cursor }) {
            let titles = await Task.detached(priority: .userInitiated) {
                Dictionary(
                    CursorHistoryProvider.conversations().map { ($0.id, $0.title) },
                    uniquingKeysWith: { first, _ in first }
                )
            }.value
            sessions = sessions.map { session in
                guard session.agent == .cursor, let title = titles[session.id] else { return session }
                var updated = session
                updated.title = title
                return updated
            }
        }

        return sessions
    }

    func loadConversation(for session: ConversationSession) async throws -> [ConversationMessage] {
        try await db.messagesForSession(sessionId: session.id)
    }

    // MARK: - Project name derivation

    /// Derive a human-readable project name from the Claude projects folder name.
    ///
    /// Examples:
    /// - "-Users-dan-Code-ScreenshotTray" -> "ScreenshotTray"
    /// - "-Users-dan-Code-Kids-Expenses" -> "Kids Expenses"
    /// - "-Users-dan-Code-ScreenshotTray--claude-worktrees-dreamy-chatelet-3b2971" -> "ScreenshotTray"
    nonisolated static func deriveProjectName(from folderName: String) -> String {
        // Strip worktree suffix for name derivation — worktrees are merged with their parent
        let baseName: String
        if let worktreeRange = folderName.range(of: "--claude-worktrees-") {
            baseName = String(folderName[..<worktreeRange.lowerBound])
        } else {
            baseName = folderName
        }

        // Split on single dashes, keeping empty subsequences to detect double dashes
        // The folder name starts with "-" (representing the leading "/")
        // e.g. "-Users-dan-Code-ScreenshotTray" splits into ["", "Users", "dan", "Code", "ScreenshotTray"]
        let components = baseName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)

        // Find the meaningful suffix after "Code" or the last well-known directory
        let knownPrefixes = ["Users", "home", "var", "tmp", "opt"]
        var meaningfulStart = 0

        if let codeIndex = components.lastIndex(of: "Code"), codeIndex + 1 < components.count {
            meaningfulStart = codeIndex + 1
        } else {
            // No "Code" found, skip known prefix directories and the username
            for (i, component) in components.enumerated() {
                if !knownPrefixes.contains(component) {
                    // This might be the username or meaningful part
                    // Skip the username (first non-prefix component)
                    if i > 0 && knownPrefixes.contains(components[i - 1]) {
                        meaningfulStart = i + 1
                    } else {
                        meaningfulStart = i
                    }
                    break
                }
            }
        }

        // Build the display name from meaningful components
        let meaningful = Array(components[min(meaningfulStart, components.count)...])

        if meaningful.isEmpty {
            return components.last ?? folderName
        }

        return meaningful.joined(separator: " ")
    }

    // MARK: - Private helpers

    /// Collect all .jsonl files recursively under a directory.
    nonisolated static func collectJSONLFiles(under directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    /// Runs in a detached task because file-attribute lookups over a network
    /// source or thousands of sessions can block for long enough to trip the
    /// app-hang watchdog.
    private nonisolated static func modificationDateIfRegularFile(at url: URL) -> Date? {
        regularFileAttributes(at: url)?.modificationDate
    }

    /// Size is read alongside the date so an appended transcript can be resumed
    /// from its recorded byte offset.
    nonisolated static func regularFileAttributes(at url: URL) -> (modificationDate: Date, size: Int)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true,
              let date = values.contentModificationDate else {
            return nil
        }
        return (date, values.fileSize ?? 0)
    }

    /// Derive the project path from a JSONL file URL.
    /// The project path is the first directory under ~/.claude/projects/
    private func deriveProjectPath(from fileURL: URL) -> String {
        let projectsDir = claudeProjectsPath.path
        let filePath = fileURL.path

        guard filePath.hasPrefix(projectsDir) else {
            return fileURL.deletingLastPathComponent().path
        }

        // Strip the projects directory prefix to get "ProjectFolder/rest/of/path.jsonl"
        let relative = String(filePath.dropFirst(projectsDir.count + 1)) // +1 for trailing slash
        // The project folder is the first path component
        let projectFolder = relative.components(separatedBy: "/").first ?? relative
        return claudeProjectsPath.appendingPathComponent(projectFolder).path
    }
}
