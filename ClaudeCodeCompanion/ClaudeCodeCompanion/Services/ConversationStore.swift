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

        for (index, file) in jsonlFiles.enumerated() {
            indexingProgress = (index + 1, jsonlFiles.count)
            try await indexFile(at: file)
        }

        try await loadProjects()
    }

    // MARK: - Single file index

    func indexFile(at url: URL) async throws {
        guard let modDate = await Task.detached(priority: .utility, operation: {
            Self.modificationDateIfRegularFile(at: url)
        }).value else { return }

        let needsReindex = await db.needsReindex(path: url.path, modificationDate: modDate)
        guard needsReindex else { return }

        let projectPath = deriveProjectPath(from: url)
        let isSubagent = JSONLParser.isSubagentPath(url)

        let messages = try await parser.parseFile(at: url, projectPath: projectPath)
        guard !messages.isEmpty else { return }

        try await db.indexMessages(
            messages,
            filePath: url.path,
            modificationDate: modDate,
            projectPath: projectPath,
            isSubagent: isSubagent
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
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true else {
            return nil
        }
        return values.contentModificationDate
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
