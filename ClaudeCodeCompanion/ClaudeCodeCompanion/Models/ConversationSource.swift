import Foundation

/// An external conversation source — another Mac's ~/.claude/projects folder
/// accessed via network share, synced folder, or any local path.
struct ConversationSource: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String        // e.g. "MacBook Air"
    var path: String        // e.g. "/Volumes/MacBook Air/.claude/projects"
    var lastIndexed: Date?
    var isEnabled: Bool

    init(name: String, path: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.lastIndexed = nil
        self.isEnabled = true
    }

    /// Whether the source path is currently reachable on the filesystem.
    var isAccessible: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Whether the last index was more than 24 hours ago (or never indexed).
    var isStale: Bool {
        guard let lastIndexed else { return true }
        return Date().timeIntervalSince(lastIndexed) > 24 * 3600
    }

    // MARK: - Persistence

    private static let storageKey = "conversationSources"

    static func loadAll() -> [ConversationSource] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let sources = try? JSONDecoder().decode([ConversationSource].self, from: data) else {
            return []
        }
        return sources
    }

    static func saveAll(_ sources: [ConversationSource]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
