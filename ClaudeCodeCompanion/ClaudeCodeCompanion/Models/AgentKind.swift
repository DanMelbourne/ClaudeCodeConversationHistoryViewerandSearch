import Foundation

/// A coding agent whose conversation history the app can read.
///
/// Every session, message and search result carries the agent it came from so
/// the UI can badge it and the index can be filtered per agent.
enum AgentKind: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Short label for badges where space is tight.
    var badgeText: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        }
    }

    /// Default on-disk location this agent stores its history in.
    var defaultHistoryLocation: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .codex:
            return home.appendingPathComponent(".codex/sessions", isDirectory: true)
        case .cursor:
            return home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage",
                isDirectory: true
            )
        }
    }

    /// UserDefaults key controlling whether this agent's history is indexed.
    var enabledDefaultsKey: String { "agentEnabled.\(rawValue)" }

    /// Whether the user has this agent switched on. Claude Code is always on.
    static func isEnabled(_ agent: AgentKind, defaults: UserDefaults = .standard) -> Bool {
        guard agent != .claude else { return true }
        if defaults.object(forKey: agent.enabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: agent.enabledDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool, for agent: AgentKind, defaults: UserDefaults = .standard) {
        guard agent != .claude else { return }
        defaults.set(enabled, forKey: agent.enabledDefaultsKey)
    }
}

// MARK: - Project path encoding

/// Translates a real working directory into the folder-name form Claude Code
/// uses under `~/.claude/projects` (`/Users/dan/Code/My App` →
/// `-Users-dan-Code-My-App`).
///
/// Codex and Cursor record a plain `cwd`/repo path. Encoding it the same way
/// lets one project row hold every agent's sessions for the same folder.
enum ProjectPathEncoder {
    static func encodedFolderName(for workingDirectory: String) -> String {
        var out = ""
        out.reserveCapacity(workingDirectory.count)
        for scalar in workingDirectory.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber || ch == "-" {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        return out
    }

    /// The synthetic `project_path` used in the index for a working directory.
    /// It points at the Claude projects folder so Claude, Codex and Cursor
    /// sessions for the same directory group into a single project.
    static func projectPath(
        for workingDirectory: String,
        claudeProjectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    ) -> String {
        claudeProjectsRoot
            .appendingPathComponent(encodedFolderName(for: workingDirectory))
            .path
    }
}
