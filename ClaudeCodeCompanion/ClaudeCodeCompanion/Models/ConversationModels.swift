import Foundation

// MARK: - Project

/// A project derived from a folder under ~/.claude/projects/
/// Worktree folders (containing `--claude-worktrees-`) are merged into their
/// parent project. `additionalPaths` holds the worktree folder URLs.
struct Project: Identifiable, Hashable {
    let id: String
    let displayName: String
    let path: URL                   // primary (base) project path
    var additionalPaths: [URL]      // worktree paths merged into this project
    var sessionCount: Int
    var lastActivityDate: Date?
    /// Which agents contributed sessions to this project.
    var agents: Set<AgentKind> = [.claude]
    /// The real working directory the agents ran in, when the index knows it.
    /// Used for Reveal in Finder — the transcripts folder only exists for
    /// projects Claude Code has written to.
    var workingDirectory: String?

    /// The best folder to reveal in Finder, or nil when nothing exists on disk.
    var revealTarget: URL? {
        let fileManager = FileManager.default
        if let workingDirectory, fileManager.fileExists(atPath: workingDirectory) {
            return URL(fileURLWithPath: workingDirectory)
        }
        if fileManager.fileExists(atPath: path.path) { return path }
        return nil
    }

    /// All paths belonging to this project (base + worktrees).
    var allPaths: [URL] { [path] + additionalPaths }

    /// Whether a given filesystem path belongs to this project.
    /// Matches exact paths AND worktree paths whose base name matches this project's id.
    /// This handles search results from worktree folders that no longer exist on disk.
    func ownsPath(_ testPath: String) -> Bool {
        // Direct match against known paths
        if allPaths.contains(where: { $0.path == testPath }) {
            return true
        }
        // Worktree fallback: if testPath is a worktree of this project's base name,
        // match even if the worktree folder was deleted from disk.
        let testFolderName = URL(fileURLWithPath: testPath).lastPathComponent
        if let worktreeRange = testFolderName.range(of: "--claude-worktrees-") {
            let baseName = String(testFolderName[..<worktreeRange.lowerBound])
            return baseName == id
        }
        // Also check if testPath's folder name matches this project's id directly
        return testFolderName == id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ConversationSession

/// A conversation session (one JSONL file for Claude Code and Codex; one
/// composer record for Cursor, where `filePath` points at Cursor's database).
struct ConversationSession: Identifiable, Hashable {
    let id: String
    let projectId: String
    let filePath: URL
    var firstUserMessage: String?
    var timestamp: Date?
    var messageCount: Int
    var isSubagent: Bool
    var agent: AgentKind = .claude
    /// Cursor conversations have a user-visible title; nil elsewhere.
    var title: String?
}

// MARK: - ConversationMessage

/// A single message in a conversation
struct ConversationMessage: Identifiable, Hashable {
    let id: String
    let sessionId: String
    let type: MessageType
    let timestamp: Date
    let contentText: String
    let contentRaw: String
    let parentUuid: String?
    let cwd: String?
    let gitBranch: String?
    var agent: AgentKind = .claude

    enum MessageType: String, Codable, Hashable {
        case user
        case assistant
        case system
        case attachment
        case queueOperation = "queue-operation"
        case lastPrompt = "last-prompt"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ConversationMessage, rhs: ConversationMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ContentBlock

/// Structured content blocks for rich rendering
enum ContentBlock: Hashable {
    case text(String)
    case thinking(String)
    case toolUse(name: String, inputJSON: String)
    case toolResult(content: String)
}

// MARK: - ParsedMessage

/// Parsed message with structured content for rendering
struct ParsedMessage: Identifiable {
    let id: String
    let type: ConversationMessage.MessageType
    let timestamp: Date
    let blocks: [ContentBlock]
    let rawJSON: String
}

// MARK: - SearchResult

/// A result from FTS5 full-text search
struct SearchResult: Identifiable {
    let id: Int
    let sessionId: String
    let projectPath: String
    let messageUuid: String
    let messageType: String
    let timestamp: Date
    let snippet: String
    let fullText: String
    let contextBefore: String
    let contextAfter: String
    var agent: AgentKind = .claude

    var projectDisplayName: String {
        let url = URL(fileURLWithPath: projectPath)
        let folderName = url.lastPathComponent
        // Strip worktree suffix — worktrees are merged with parent projects
        let baseName: String
        if let worktreeRange = folderName.range(of: "--claude-worktrees-") {
            baseName = String(folderName[..<worktreeRange.lowerBound])
        } else {
            baseName = folderName
        }
        let components = baseName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        let knownPrefixes = ["Users", "home", "var", "tmp", "opt"]
        var meaningfulStart = 0
        if let codeIndex = components.lastIndex(of: "Code"), codeIndex + 1 < components.count {
            meaningfulStart = codeIndex + 1
        } else {
            for (i, component) in components.enumerated() {
                if !knownPrefixes.contains(component) {
                    if i > 0 && knownPrefixes.contains(components[i - 1]) {
                        meaningfulStart = i + 1
                    } else {
                        meaningfulStart = i
                    }
                    break
                }
            }
        }
        let meaningful = Array(components[min(meaningfulStart, components.count)...])
        return meaningful.isEmpty ? (components.last ?? folderName) : meaningful.joined(separator: " ")
    }

    func dynamicSnippet(query: String, contextLines: Int) -> String {
        let lines = fullText.components(separatedBy: .newlines)
        let queryLower = query.lowercased()

        for (index, line) in lines.enumerated() {
            if line.lowercased().contains(queryLower) {
                let start = max(0, index - contextLines)
                let end = min(lines.count - 1, index + contextLines)
                let snippetLines = lines[start...end]
                let joined = snippetLines.joined(separator: "\n")
                return joined.replacingOccurrences(
                    of: query,
                    with: "<mark>\(query)</mark>",
                    options: .caseInsensitive
                )
            }
        }

        return snippet
    }
}
