import SwiftUI
import Observation

// MARK: - Design Constants

enum DesignConstants {
    static let accentColor = Color(red: 0.85, green: 0.47, blue: 0.02)
    static let monoFont: Font = .system(.body, design: .monospaced)
    static let monoFontSmall: Font = .system(.caption, design: .monospaced)
    static let monoFontLarge: Font = .system(.title3, design: .monospaced)
}

// MARK: - Navigation State

enum DetailDestination: Hashable {
    case conversation
    case searchResults
    case claudeMDEditor
}

enum SearchScope: String, CaseIterable {
    case allProjects = "All Projects"
    case currentProject = "Current Project"
    case currentChat = "Current Chat"
}

enum ViewMode: String, CaseIterable {
    case index = "Index"
    case raw = "Raw"
}

// MARK: - AppViewModel

@Observable
final class AppViewModel {

    // MARK: - Navigation

    var selectedProject: Project?
    var selectedSession: ConversationSession?
    var detailDestination: DetailDestination = .conversation

    // MARK: - Projects & Sessions

    var projects: [Project] = []
    var sessions: [ConversationSession] = []
    var messages: [ParsedMessage] = []

    // MARK: - Search

    var searchText: String = ""
    var searchScope: SearchScope = .allProjects
    var viewMode: ViewMode = .index
    var contextLines: Double = 3
    var searchResults: [SearchResult] = []
    var currentSearchResultIndex: Int = 0
    var isSearchActive: Bool {
        !searchText.isEmpty && !searchResults.isEmpty
    }

    // MARK: - Indexing

    var isIndexing: Bool = false
    var indexingProgress: Double = 0
    var indexingStatus: String = ""

    // MARK: - CLAUDE.md Editor

    var claudeMDGlobalContent: String = ""
    var claudeMDProjectContent: String = ""
    var claudeMDEditorProject: Project?
    var claudeMDEditorTab: ClaudeMDTab = .global
    var claudeMDHasUnsavedChanges: Bool = false

    enum ClaudeMDTab: String, CaseIterable {
        case global = "Global"
        case project = "Project"
    }

    // MARK: - System Messages

    var showSystemMessages: Bool = false

    // MARK: - Initialization

    @MainActor
    func initialize() async {
        loadProjects()
    }

    // MARK: - Project Loading

    @MainActor
    func loadProjects() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            projects = []
            return
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            var loadedProjects: [Project] = []
            for folder in contents {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let sessionFiles = (try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "jsonl" }) ?? []

                let latestDate = sessionFiles.compactMap { file -> Date? in
                    try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }.max()

                let displayName = projectDisplayName(from: folder.lastPathComponent)

                loadedProjects.append(Project(
                    id: folder.lastPathComponent,
                    displayName: displayName,
                    path: folder,
                    sessionCount: sessionFiles.count,
                    lastActivityDate: latestDate
                ))
            }

            projects = loadedProjects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            projects = []
        }
    }

    // MARK: - Session Loading

    @MainActor
    func loadSessions(for project: Project) {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: project.path,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }

            var loadedSessions: [ConversationSession] = []
            for file in files {
                let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

                let firstLine = readFirstUserMessage(from: file)
                let lineCount = countLines(in: file)

                let isSubagent = file.lastPathComponent.contains("subagent") ||
                    file.lastPathComponent.contains("task_")

                loadedSessions.append(ConversationSession(
                    id: file.deletingPathExtension().lastPathComponent,
                    projectId: project.id,
                    filePath: file,
                    firstUserMessage: firstLine,
                    timestamp: modDate,
                    messageCount: lineCount,
                    isSubagent: isSubagent
                ))
            }

            sessions = loadedSessions.sorted {
                ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
            }
        } catch {
            sessions = []
        }
    }

    // MARK: - Message Loading

    @MainActor
    func loadMessages(for session: ConversationSession) {
        guard FileManager.default.fileExists(atPath: session.filePath.path) else {
            messages = []
            return
        }

        do {
            let data = try String(contentsOf: session.filePath, encoding: .utf8)
            let lines = data.components(separatedBy: .newlines).filter { !$0.isEmpty }

            var parsed: [ParsedMessage] = []
            for (index, line) in lines.enumerated() {
                guard let jsonData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }

                let type = parseMessageType(from: json)
                let timestamp = parseTimestamp(from: json) ?? Date(timeIntervalSince1970: TimeInterval(index))
                let blocks = parseContentBlocks(from: json)

                guard !blocks.isEmpty else { continue }

                parsed.append(ParsedMessage(
                    id: json["uuid"] as? String ?? UUID().uuidString,
                    type: type,
                    timestamp: timestamp,
                    blocks: blocks,
                    rawJSON: line
                ))
            }

            messages = parsed
        } catch {
            messages = []
        }
    }

    // MARK: - Search

    @MainActor
    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            currentSearchResultIndex = 0
            return
        }

        var results: [SearchResult] = []
        var resultId = 0

        let projectsToSearch: [Project]
        switch searchScope {
        case .allProjects:
            projectsToSearch = projects
        case .currentProject:
            if let proj = selectedProject {
                projectsToSearch = [proj]
            } else {
                projectsToSearch = projects
            }
        case .currentChat:
            if let session = selectedSession, let project = selectedProject {
                searchInSession(session, project: project, query: searchText, results: &results, resultId: &resultId)
                searchResults = results
                currentSearchResultIndex = results.isEmpty ? 0 : 0
                return
            }
            projectsToSearch = []
        }

        for project in projectsToSearch {
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: project.path,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "jsonl" }

                for file in files {
                    let session = ConversationSession(
                        id: file.deletingPathExtension().lastPathComponent,
                        projectId: project.id,
                        filePath: file,
                        firstUserMessage: nil,
                        timestamp: nil,
                        messageCount: 0,
                        isSubagent: false
                    )
                    searchInSession(session, project: project, query: searchText, results: &results, resultId: &resultId)
                }
            } catch {
                continue
            }
        }

        searchResults = results
        currentSearchResultIndex = results.isEmpty ? 0 : 0
    }

    @MainActor
    func navigateSearchResult(direction: Int) {
        guard !searchResults.isEmpty else { return }
        currentSearchResultIndex = (currentSearchResultIndex + direction + searchResults.count) % searchResults.count
    }

    // MARK: - CLAUDE.md

    @MainActor
    func loadClaudeMD() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        // Global CLAUDE.md
        let globalPath = homeDir.appendingPathComponent(".claude/CLAUDE.md")
        claudeMDGlobalContent = (try? String(contentsOf: globalPath, encoding: .utf8)) ?? ""

        // Project CLAUDE.md
        if let project = claudeMDEditorProject ?? selectedProject {
            let projectClaudeMD = findProjectClaudeMD(for: project)
            claudeMDProjectContent = (try? String(contentsOf: projectClaudeMD, encoding: .utf8)) ?? ""
        }

        claudeMDHasUnsavedChanges = false
    }

    @MainActor
    func saveClaudeMD() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        switch claudeMDEditorTab {
        case .global:
            let globalPath = homeDir.appendingPathComponent(".claude/CLAUDE.md")
            try? claudeMDGlobalContent.write(to: globalPath, atomically: true, encoding: .utf8)
        case .project:
            if let project = claudeMDEditorProject ?? selectedProject {
                let projectClaudeMD = findProjectClaudeMD(for: project)
                try? claudeMDProjectContent.write(to: projectClaudeMD, atomically: true, encoding: .utf8)
            }
        }

        claudeMDHasUnsavedChanges = false
    }

    // MARK: - Copy All Results

    @MainActor
    func copyAllSearchResults() {
        let text = searchResults.map { result in
            "[\(result.projectPath)] [\(result.messageType)] \(result.snippet)"
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private Helpers

    private func projectDisplayName(from folderName: String) -> String {
        return ConversationStore.deriveProjectName(from: folderName)
    }

    private func readFirstUserMessage(from file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { handle.closeFile() }

        let chunk = handle.readData(ofLength: 65536)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "human" || type == "user" else { continue }

            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                return String(content.prefix(200))
            }
            if let message = json["message"] as? [String: Any],
               let contentArr = message["content"] as? [[String: Any]] {
                for block in contentArr {
                    if let text = block["text"] as? String {
                        return String(text.prefix(200))
                    }
                }
            }
        }
        return nil
    }

    private func countLines(in file: URL) -> Int {
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return data.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
    }

    private func parseMessageType(from json: [String: Any]) -> ConversationMessage.MessageType {
        if let type = json["type"] as? String {
            switch type {
            case "human", "user": return .user
            case "assistant": return .assistant
            case "system": return .system
            default: return .system
            }
        }
        if let role = (json["message"] as? [String: Any])?["role"] as? String {
            switch role {
            case "human", "user": return .user
            case "assistant": return .assistant
            case "system": return .system
            default: return .system
            }
        }
        return .system
    }

    private func parseTimestamp(from json: [String: Any]) -> Date? {
        if let ts = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: ts) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: ts)
        }
        if let ts = json["timestamp"] as? Double {
            return Date(timeIntervalSince1970: ts / 1000)
        }
        return nil
    }

    private func parseContentBlocks(from json: [String: Any]) -> [ContentBlock] {
        var blocks: [ContentBlock] = []

        // Try message.content as array
        if let message = json["message"] as? [String: Any],
           let contentArr = message["content"] as? [[String: Any]] {
            for block in contentArr {
                if let type = block["type"] as? String {
                    switch type {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            blocks.append(.text(text))
                        }
                    case "thinking":
                        if let text = block["thinking"] as? String ?? block["text"] as? String, !text.isEmpty {
                            blocks.append(.thinking(text))
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "Unknown Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let inputJSON = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        blocks.append(.toolUse(name: name, inputJSON: inputJSON))
                    case "tool_result":
                        if let content = block["content"] as? String {
                            blocks.append(.toolResult(content: content))
                        } else if let contentArr = block["content"] as? [[String: Any]] {
                            for sub in contentArr {
                                if let text = sub["text"] as? String {
                                    blocks.append(.toolResult(content: text))
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }

        // Try message.content as string
        if blocks.isEmpty,
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            blocks.append(.text(content))
        }

        return blocks
    }

    private func searchInSession(_ session: ConversationSession, project: Project, query: String, results: inout [SearchResult], resultId: inout Int) {
        guard let data = try? String(contentsOf: session.filePath, encoding: .utf8) else { return }

        let lines = data.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let queryLower = query.lowercased()

        for line in lines {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            let type = parseMessageType(from: json)
            let timestamp = parseTimestamp(from: json) ?? Date()
            let fullText = extractFullText(from: json)

            guard fullText.lowercased().contains(queryLower) else { continue }

            let snippet = createSnippet(from: fullText, query: query, contextLines: Int(contextLines))

            results.append(SearchResult(
                id: resultId,
                sessionId: session.id,
                projectPath: project.displayName,
                messageType: type.rawValue,
                timestamp: timestamp,
                snippet: snippet,
                fullText: fullText,
                contextBefore: "",
                contextAfter: ""
            ))
            resultId += 1
        }
    }

    private func extractFullText(from json: [String: Any]) -> String {
        var texts: [String] = []

        if let message = json["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                texts.append(content)
            } else if let contentArr = message["content"] as? [[String: Any]] {
                for block in contentArr {
                    if let text = block["text"] as? String {
                        texts.append(text)
                    }
                    if let text = block["thinking"] as? String {
                        texts.append(text)
                    }
                }
            }
        }

        return texts.joined(separator: "\n")
    }

    private func createSnippet(from text: String, query: String, contextLines: Int) -> String {
        let lines = text.components(separatedBy: .newlines)
        let queryLower = query.lowercased()

        for (index, line) in lines.enumerated() {
            if line.lowercased().contains(queryLower) {
                let start = max(0, index - contextLines)
                let end = min(lines.count - 1, index + contextLines)
                let snippetLines = lines[start...end]
                let joined = snippetLines.joined(separator: "\n")

                // Wrap matched text in <mark> tags for highlighting
                return joined.replacingOccurrences(
                    of: query,
                    with: "<mark>\(query)</mark>",
                    options: .caseInsensitive
                )
            }
        }

        return String(text.prefix(300))
    }

    private func findProjectClaudeMD(for project: Project) -> URL {
        // Decode the project folder name to get the actual project path
        let folderName = project.id
        let decoded = folderName.replacingOccurrences(of: "-", with: "/")
        let projectPath = URL(fileURLWithPath: decoded)
        return projectPath.appendingPathComponent("CLAUDE.md")
    }
}
