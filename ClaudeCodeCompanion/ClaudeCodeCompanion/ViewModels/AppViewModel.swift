import AppKit
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
    var isLoadingSessions: Bool = false
    var isLoadingMessages: Bool = false
    var exportErrorMessage: String?
    var navigationErrorMessage: String?
    var unavailableSearchResult: SearchResult?
    var cachedConversationSessionID: String?
    var cachedConversationNotice: String?

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

    // MARK: - Scroll Target

    var scrollToMessageId: String?

    // MARK: - Indexing

    var isIndexing: Bool = false
    var indexingProgress: Double = 0
    var indexingStatus: String = ""

    // MARK: - External Sources

    var externalSources: [ConversationSource] = []
    var showSourcesManager: Bool = false

    // MARK: - Agents

    /// Mirrors the persisted per-agent switches so SwiftUI can observe them.
    var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases.filter { AgentKind.isEnabled($0) })

    @MainActor
    func setAgent(_ agent: AgentKind, enabled: Bool) {
        guard agent != .claude else { return }
        AgentKind.setEnabled(enabled, for: agent)
        if enabled { enabledAgents.insert(agent) } else { enabledAgents.remove(agent) }
        configureFileWatchers()
        Task { @MainActor in await reindexAgents() }
    }

    /// Re-read Codex and Cursor history and refresh the project list.
    @MainActor
    func reindexAgents() async {
        guard let store else { return }
        isIndexing = true
        indexingStatus = "Updating Codex and Cursor history…"
        do {
            try await store.indexOtherAgents()
        } catch {
            indexingStatus = "Could not read other agents' history"
        }
        isIndexing = false
        indexingStatus = ""
        loadProjects()
    }

    // MARK: - Debounce

    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var navigateTask: Task<Void, Never>?
    @ObservationIgnored private var fileWatchers: [FileWatcher] = []
    @ObservationIgnored private var watcherRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var watcherRefreshGeneration = UUID()

    /// When true, the sidebar's onChange(of: selectedProject) should NOT reset
    /// the session or reload sessions — navigateToSearchResult handles it.
    var isNavigatingFromSearch: Bool = false

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

    // MARK: - In-Conversation Search

    var showConversationSearch: Bool = false

    // MARK: - Database

    var store: ConversationStore?

    // MARK: - Initialization

    @MainActor
    func initialize() async {
        externalSources = ConversationSource.loadAll()
        loadProjects()
        let convStore = ConversationStore()
        self.store = convStore
        isIndexing = true
        indexingStatus = "Building index..."
        do {
            try await convStore.performFullIndex()
            // Index accessible external sources
            for i in externalSources.indices where externalSources[i].isEnabled && externalSources[i].isAccessible {
                indexingStatus = "Indexing \(externalSources[i].name)..."
                try await convStore.indexDirectory(URL(fileURLWithPath: externalSources[i].path))
                externalSources[i].lastIndexed = Date()
            }
            ConversationSource.saveAll(externalSources)
        } catch {
            indexingStatus = "Index error: \(error.localizedDescription)"
        }
        isIndexing = false
        indexingStatus = ""
        loadProjects() // reload to include external source projects
        configureFileWatchers()
    }

    // MARK: - Project Loading

    @MainActor
    func loadProjects() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")

        var allDirectories: [URL] = []

        // Local projects directory
        if FileManager.default.fileExists(atPath: projectsDir.path) {
            allDirectories.append(projectsDir)
        }

        // External sources (silently skip inaccessible ones)
        for source in externalSources where source.isEnabled && source.isAccessible {
            allDirectories.append(URL(fileURLWithPath: source.path))
        }

        guard !allDirectories.isEmpty else {
            projects = []
            return
        }

        let store = self.store
        Task.detached(priority: .userInitiated) { [allDirectories] in
            let loadedProjects = Self.enumerateProjects(in: allDirectories)
            var agentProjects: [Project] = []
            if let store {
                agentProjects = (try? await store.projects(agents: Self.secondaryAgents)) ?? []
            }
            let merged = Self.merge(agentProjects: agentProjects, into: loadedProjects)
            await MainActor.run { [weak self] in
                self?.projects = merged
            }
        }
    }

    /// Agents whose history lives outside `~/.claude/projects` and therefore
    /// comes from the index rather than the filesystem walk.
    static var secondaryAgents: Set<AgentKind> {
        Set(AgentKind.allCases.filter { $0 != .claude && AgentKind.isEnabled($0) })
    }

    /// Fold Codex/Cursor projects into the Claude project list, merging any
    /// that point at the same working directory so one row shows every agent.
    nonisolated static func merge(agentProjects: [Project], into fileProjects: [Project]) -> [Project] {
        // Worktree folders belong to their parent project, exactly as the
        // filesystem walk already merges them.
        func baseName(_ folder: String) -> String {
            guard let range = folder.range(of: "--claude-worktrees-") else { return folder }
            return String(folder[..<range.lowerBound])
        }

        var byFolderName: [String: Project] = [:]
        var order: [String] = []

        for project in fileProjects {
            let key = baseName(project.path.lastPathComponent)
            byFolderName[key] = project
            order.append(key)
        }

        for project in agentProjects {
            let key = baseName(project.path.lastPathComponent)
            if var existing = byFolderName[key] {
                existing.sessionCount += project.sessionCount
                existing.agents.formUnion(project.agents)
                existing.workingDirectory = existing.workingDirectory ?? project.workingDirectory
                let dates = [existing.lastActivityDate, project.lastActivityDate].compactMap { $0 }
                existing.lastActivityDate = dates.max()
                byFolderName[key] = existing
            } else {
                byFolderName[key] = Project(
                    id: key,
                    displayName: ConversationStore.deriveProjectName(from: key),
                    path: project.path.deletingLastPathComponent().appendingPathComponent(key),
                    additionalPaths: [],
                    sessionCount: project.sessionCount,
                    lastActivityDate: project.lastActivityDate,
                    agents: project.agents,
                    workingDirectory: project.workingDirectory
                )
                order.append(key)
            }
        }

        return order.compactMap { byFolderName[$0] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Enumerate project folders on a background thread. Pure function, no main-thread dependency.
    private nonisolated static func enumerateProjects(in directories: [URL]) -> [Project] {
        struct FolderInfo {
            let url: URL
            let sessionCount: Int
            let latestDate: Date?
        }

        let fm = FileManager.default
        var folderInfos: [FolderInfo] = []

        for projectsURL in directories {
            guard let contents = try? fm.contentsOfDirectory(
                at: projectsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for folder in contents {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let sessionFiles = (try? fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "jsonl" }) ?? []

                let latestDate = sessionFiles.compactMap { file -> Date? in
                    try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }.max()

                folderInfos.append(FolderInfo(url: folder, sessionCount: sessionFiles.count, latestDate: latestDate))
            }
        }

        // Group worktree folders with their base project
        var baseProjects: [String: (base: FolderInfo?, worktrees: [FolderInfo])] = [:]

        for info in folderInfos {
            let folderName = info.url.lastPathComponent
            if let worktreeRange = folderName.range(of: "--claude-worktrees-") {
                let baseName = String(folderName[..<worktreeRange.lowerBound])
                if baseProjects[baseName] != nil {
                    baseProjects[baseName]!.worktrees.append(info)
                } else {
                    baseProjects[baseName] = (base: nil, worktrees: [info])
                }
            } else {
                if baseProjects[folderName] != nil {
                    // Base folder found after worktrees were already added — assign as base, not worktree
                    baseProjects[folderName]!.base = info
                } else {
                    baseProjects[folderName] = (base: info, worktrees: [])
                }
            }
        }

        // Build merged projects
        var loadedProjects: [Project] = []
        for (baseName, group) in baseProjects {
            let primaryInfo: FolderInfo
            let worktreeInfos: [FolderInfo]
            if let base = group.base {
                primaryInfo = base
                worktreeInfos = group.worktrees
            } else if let firstWorktree = group.worktrees.first {
                primaryInfo = firstWorktree
                worktreeInfos = Array(group.worktrees.dropFirst())
            } else {
                continue
            }

            let totalSessionCount = primaryInfo.sessionCount + worktreeInfos.reduce(0) { $0 + $1.sessionCount }
            let allDates = ([primaryInfo.latestDate] + worktreeInfos.map(\.latestDate)).compactMap { $0 }
            let latestDate = allDates.max()
            let additionalPaths = worktreeInfos.map(\.url)

            let displayName = ConversationStore.deriveProjectName(from: baseName)

            loadedProjects.append(Project(
                id: baseName,
                displayName: displayName,
                path: primaryInfo.url,
                additionalPaths: additionalPaths,
                sessionCount: totalSessionCount,
                lastActivityDate: latestDate
            ))
        }

        return loadedProjects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Session Loading

    @ObservationIgnored private var loadSessionsTask: Task<Void, Never>?

    @MainActor
    func loadSessions(for project: Project) {
        loadSessionsTask?.cancel()
        navigateTask?.cancel()
        isLoadingSessions = true

        let projectId = project.id
        let allPaths = project.allPaths
        let store = self.store

        loadSessionsTask = Task.detached(priority: .userInitiated) { [weak self] in
            var loadedSessions = Self.enumerateSessions(projectId: projectId, paths: allPaths)
            if let store {
                let agentSessions = (try? await store.sessions(
                    projectPaths: allPaths.map(\.path),
                    agents: Self.secondaryAgents
                )) ?? []
                // Sessions come back keyed by the index's project path; retag
                // them with the sidebar project id so selection matches.
                loadedSessions.append(contentsOf: agentSessions.map { session in
                    ConversationSession(
                        id: session.id,
                        projectId: projectId,
                        filePath: session.filePath,
                        firstUserMessage: session.firstUserMessage,
                        timestamp: session.timestamp,
                        messageCount: session.messageCount,
                        isSubagent: session.isSubagent,
                        agent: session.agent,
                        title: session.title
                    )
                })
                loadedSessions.sort { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.sessions = loadedSessions
                self.isLoadingSessions = false
            }
        }
    }

    /// Enumerate sessions on a background thread. No main-thread file I/O.
    private nonisolated static func enumerateSessions(projectId: String, paths: [URL]) -> [ConversationSession] {
        let fm = FileManager.default
        var loadedSessions: [ConversationSession] = []

        for folderURL in paths {
            guard let files = try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter({ $0.pathExtension == "jsonl" }) else { continue }

            for file in files {
                let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

                let firstLine = readFirstUserMessageBackground(from: file)
                let lineCount = countLinesEfficient(in: file)

                let isSubagent = file.lastPathComponent.contains("subagent") ||
                    file.lastPathComponent.contains("task_")

                loadedSessions.append(ConversationSession(
                    id: file.deletingPathExtension().lastPathComponent,
                    projectId: projectId,
                    filePath: file,
                    firstUserMessage: firstLine,
                    timestamp: modDate,
                    messageCount: lineCount,
                    isSubagent: isSubagent
                ))
            }
        }

        return loadedSessions.sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
    }

    // MARK: - Message Loading

    @ObservationIgnored private var loadMessagesTask: Task<Void, Never>?

    @MainActor
    func loadMessages(for session: ConversationSession) {
        loadMessagesTask?.cancel()
        navigateTask?.cancel()

        guard session.id != cachedConversationSessionID else {
            isLoadingMessages = false
            detailDestination = .conversation
            return
        }

        cachedConversationSessionID = nil
        cachedConversationNotice = nil

        // Cursor keeps its history in a database, so only file-backed agents
        // are checked for a missing transcript.
        if session.agent != .cursor,
           !FileManager.default.fileExists(atPath: session.filePath.path) {
            messages = []
            return
        }

        isLoadingMessages = true
        let filePath = session.filePath
        let agent = session.agent
        let sessionId = session.id

        loadMessagesTask = Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = Self.parseMessages(agent: agent, filePath: filePath, sessionId: sessionId)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.messages = parsed
                self.isLoadingMessages = false
            }
        }
    }

    // MARK: - Conversation Export

    @MainActor
    func presentSelectedProjectExportSavePanel() {
        guard let project = selectedProject else { return }

        let panel = NSSavePanel()
        panel.title = "Export Project Conversations"
        panel.nameFieldStringValue = "\(project.displayName) Conversation History.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.exportProjectConversations(for: project, to: destination)
        }

        guard let window = presentationWindow else {
            exportErrorMessage = "Open the main window, then choose Export Project Conversations again."
            return
        }
        panel.beginSheetModal(for: window, completionHandler: complete)
    }

    @MainActor
    func exportProjectConversations(for project: Project, to destination: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try ConversationExportService.exportProjectConversations(
                    from: project,
                    to: destination
                )
                await MainActor.run { [weak self] in
                    self?.presentExportCompleteAlert(result: result, destination: destination)
                }
            } catch {
                await MainActor.run {
                    self?.exportErrorMessage = "The history could not be exported. Choose another location and try again."
                }
            }
        }
    }

    @MainActor
    private func presentExportCompleteAlert(
        result: ConversationExportService.ExportResult,
        destination: URL
    ) {
        let alert = NSAlert()
        alert.messageText = "Export Complete"
        alert.informativeText = "Exported \(result.messageCount) chat messages from \(result.conversationCount) conversations to \(destination.lastPathComponent)."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
        guard let window = presentationWindow else { return }
        alert.beginSheetModal(for: window, completionHandler: complete)
    }

    /// Load one session's messages from whichever agent produced it.
    nonisolated static func parseMessages(agent: AgentKind, filePath: URL, sessionId: String) -> [ParsedMessage] {
        switch agent {
        case .claude:
            return parseMessagesStreaming(from: filePath)
        case .codex:
            guard let session = CodexHistoryProvider.parseSession(at: filePath) else { return [] }
            return parsedMessages(from: session.messages)
        case .cursor:
            guard let conversation = CursorHistoryProvider.conversations().first(where: { $0.id == sessionId })
            else { return [] }
            return parsedMessages(from: CursorHistoryProvider.messages(for: conversation))
        }
    }

    /// Convert transcoded agent messages into the renderer's block form.
    nonisolated static func parsedMessages(from messages: [ConversationMessage]) -> [ParsedMessage] {
        messages.compactMap { message in
            let blocks = JSONLParser.parseContentBlocks(from: message.contentRaw)
            guard !blocks.isEmpty else { return nil }
            return ParsedMessage(
                id: message.id,
                type: message.type,
                timestamp: message.timestamp,
                blocks: blocks,
                rawJSON: message.contentRaw
            )
        }
    }

    /// Stream-parse a JSONL file into ParsedMessages without loading the entire file into memory.
    private nonisolated static func parseMessagesStreaming(from filePath: URL) -> [ParsedMessage] {
        guard let handle = try? FileHandle(forReadingFrom: filePath) else { return [] }
        defer { handle.closeFile() }

        var parsed: [ParsedMessage] = []
        let bufferSize = 256 * 1024 // 256KB chunks
        var leftover = ""
        var lineIndex = 0

        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            guard let chunkString = String(data: chunk, encoding: .utf8) else { continue }
            leftover += chunkString
            var lines = leftover.components(separatedBy: "\n")
            leftover = lines.removeLast() // incomplete line

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let msg = parseLineIntoParsedMessage(trimmed, lineIndex: lineIndex) {
                    parsed.append(msg)
                }
                lineIndex += 1
            }
        }

        // Handle final leftover
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let msg = parseLineIntoParsedMessage(trimmed, lineIndex: lineIndex) {
            parsed.append(msg)
        }

        return parsed
    }

    /// Parse a single JSONL line into a ParsedMessage. Thread-safe static method.
    private nonisolated static func parseLineIntoParsedMessage(_ line: String, lineIndex: Int) -> ParsedMessage? {
        guard let jsonData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        let type = parseMessageTypeStatic(from: json)
        let timestamp = parseTimestampStatic(from: json) ?? Date(timeIntervalSince1970: TimeInterval(lineIndex))
        let blocks = parseContentBlocksStatic(from: json)

        guard !blocks.isEmpty else { return nil }

        return ParsedMessage(
            id: json["uuid"] as? String ?? UUID().uuidString,
            type: type,
            timestamp: timestamp,
            blocks: blocks,
            rawJSON: line
        )
    }

    // MARK: - Search

    @MainActor
    func performSearch() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            currentSearchResultIndex = 0
            return
        }

        do {
            guard let store else { return }

            switch searchScope {
            case .allProjects:
                let results = try await store.db.search(
                    query: searchText,
                    projectPath: nil,
                    sessionId: nil,
                    limit: 500
                )
                searchResults = results

            case .currentProject:
                guard let project = selectedProject else {
                    searchResults = []
                    currentSearchResultIndex = 0
                    return
                }
                // Match the project's base folder AND all its worktrees (incl. ones
                // deleted from disk) via a single base-path query.
                let basePath = project.path
                    .deletingLastPathComponent()
                    .appendingPathComponent(project.id)
                    .path
                let results = try await store.db.search(
                    query: searchText,
                    projectBasePath: basePath,
                    sessionId: nil,
                    limit: 500
                )
                searchResults = results

            case .currentChat:
                let results = try await store.db.search(
                    query: searchText,
                    projectPath: nil,
                    sessionId: selectedSession?.id,
                    limit: 500
                )
                searchResults = results
            }

            currentSearchResultIndex = 0
        } catch {
            searchResults = []
            currentSearchResultIndex = 0
        }
    }

    @MainActor
    func navigateSearchResult(direction: Int) {
        guard !searchResults.isEmpty else { return }
        currentSearchResultIndex = (currentSearchResultIndex + direction + searchResults.count) % searchResults.count
    }

    @MainActor
    func debouncedSearch() {
        searchDebounceTask?.cancel()

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            currentSearchResultIndex = 0
            detailDestination = .conversation
            return
        }

        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await performSearch()
            if !searchResults.isEmpty {
                detailDestination = .searchResults
            }
        }
    }

    @MainActor
    func immediateSearch() async {
        searchDebounceTask?.cancel()
        await performSearch()
        if !searchResults.isEmpty {
            detailDestination = .searchResults
        }
    }

    @MainActor
    func navigateToSearchResult(_ result: SearchResult) {
        // Match project by any of its paths (base or worktree)
        guard let project = projects.first(where: { $0.ownsPath(result.projectPath) }) else { return }

        // Cancel any in-flight session/message loads and prior navigations
        loadSessionsTask?.cancel()
        loadMessagesTask?.cancel()
        navigateTask?.cancel()

        // Prevent the sidebar's onChange from resetting session/destination
        isNavigatingFromSearch = true
        isLoadingSessions = true
        isLoadingMessages = true
        navigationErrorMessage = nil
        unavailableSearchResult = nil
        cachedConversationSessionID = nil
        cachedConversationNotice = nil

        let projectId = project.id
        let allPaths = project.allPaths
        let sessionId = result.sessionId
        let targetUuid = result.messageUuid
        let store = self.store

        // Load sessions and messages in background, then navigate.
        // Assign to tracked tasks so future calls can cancel this one.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // Always clear the navigation flag when this task exits, regardless of path.
            defer {
                Task { @MainActor [weak self] in
                    self?.isNavigatingFromSearch = false
                    self?.isLoadingSessions = false
                    self?.isLoadingMessages = false
                }
            }

            var loadedSessions = Self.enumerateSessions(projectId: projectId, paths: allPaths)

            // Codex and Cursor sessions are not files under the project folder,
            // so they come from the index alongside the Claude transcripts.
            if let store {
                let agentSessions = (try? await store.sessions(
                    projectPaths: allPaths.map(\.path),
                    agents: Self.secondaryAgents
                )) ?? []
                loadedSessions.append(contentsOf: agentSessions.map { session in
                    ConversationSession(
                        id: session.id,
                        projectId: projectId,
                        filePath: session.filePath,
                        firstUserMessage: session.firstUserMessage,
                        timestamp: session.timestamp,
                        messageCount: session.messageCount,
                        isSubagent: session.isSubagent,
                        agent: session.agent,
                        title: session.title
                    )
                })
                loadedSessions.sort { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            }

            var session = loadedSessions.first(where: { $0.id == sessionId })

            if session == nil {
                // Search for subagent file
                let fm = FileManager.default
                for folderURL in allPaths {
                    guard let enumerator = fm.enumerator(
                        at: folderURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for case let url as URL in enumerator {
                        if url.pathExtension == "jsonl",
                           url.deletingPathExtension().lastPathComponent == sessionId {
                            let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                            session = ConversationSession(
                                id: sessionId,
                                projectId: projectId,
                                filePath: url,
                                firstUserMessage: nil,
                                timestamp: modDate,
                                messageCount: 0,
                                isSubagent: true
                            )
                            break
                        }
                    }
                    if session != nil { break }
                }
            }

            guard let session else {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.navigationErrorMessage = "The original conversation file is no longer available on disk."
                    self.unavailableSearchResult = result
                    self.detailDestination = .searchResults
                }
                return
            }
            guard !Task.isCancelled else { return }
            let parsed = Self.parseMessages(
                agent: session.agent,
                filePath: session.filePath,
                sessionId: session.id
            )
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.selectedProject = project
                self.sessions = loadedSessions
                self.selectedSession = session
                self.messages = parsed
                self.detailDestination = .conversation
            }

            // Small delay for scroll view to render
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run { [weak self] in
                self?.scrollToMessageId = targetUuid
            }
        }
        navigateTask = task
    }

    @MainActor
    func viewCachedConversation() {
        guard let result = unavailableSearchResult,
              let project = projects.first(where: { $0.ownsPath(result.projectPath) }),
              let store else {
            navigationErrorMessage = "The cached copy is no longer available."
            return
        }

        navigationErrorMessage = nil
        isNavigatingFromSearch = true
        isLoadingSessions = true
        isLoadingMessages = true

        let cachedSession = ConversationSession(
            id: result.sessionId,
            projectId: project.id,
            filePath: project.path.appendingPathComponent("\(result.sessionId).jsonl"),
            firstUserMessage: "Cached copy — original JSONL unavailable",
            timestamp: result.timestamp,
            messageCount: 0,
            isSubagent: false
        )
        let projectId = project.id
        let allPaths = project.allPaths

        Task { @MainActor [weak self] in
            defer {
                self?.isNavigatingFromSearch = false
                self?.isLoadingSessions = false
                self?.isLoadingMessages = false
            }

            do {
                let cachedMessages = try await store.loadConversation(for: cachedSession)
                let reconstructedMessages = Self.cachedParsedMessages(from: cachedMessages)
                guard !reconstructedMessages.isEmpty else {
                    self?.navigationErrorMessage = "The cached copy contains no user or Claude messages."
                    self?.detailDestination = .searchResults
                    return
                }

                let diskSessions = await Task.detached(priority: .userInitiated) {
                    Self.enumerateSessions(projectId: projectId, paths: allPaths)
                }.value
                guard let self else { return }

                let recoveredSession = ConversationSession(
                    id: cachedSession.id,
                    projectId: cachedSession.projectId,
                    filePath: cachedSession.filePath,
                    firstUserMessage: cachedSession.firstUserMessage,
                    timestamp: cachedSession.timestamp,
                    messageCount: reconstructedMessages.count,
                    isSubagent: cachedSession.isSubagent
                )
                self.selectedProject = project
                self.sessions = [recoveredSession] + diskSessions
                self.messages = reconstructedMessages
                self.cachedConversationSessionID = recoveredSession.id
                self.cachedConversationNotice = "Cached copy — original JSONL unavailable"
                self.selectedSession = recoveredSession
                self.unavailableSearchResult = nil
                self.detailDestination = .conversation
            } catch {
                self?.navigationErrorMessage = "The cached copy could not be loaded. Try searching again."
                self?.detailDestination = .searchResults
            }
        }
    }

    nonisolated static func cachedParsedMessages(from messages: [ConversationMessage]) -> [ParsedMessage] {
        messages.compactMap { message in
            guard message.type == .user || message.type == .assistant else { return nil }
            return ParsedMessage(
                id: message.id,
                type: message.type,
                timestamp: message.timestamp,
                blocks: JSONLParser.parseContentBlocks(from: message.contentRaw),
                rawJSON: message.contentRaw
            )
        }
    }


    // MARK: - CLAUDE.md

    @MainActor
    func loadClaudeMD() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let globalPath = homeDir.appendingPathComponent(".claude/CLAUDE.md")
        let projectPath: URL?
        if let project = claudeMDEditorProject ?? selectedProject {
            projectPath = findProjectClaudeMD(for: project)
        } else {
            projectPath = nil
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let globalContent = (try? String(contentsOf: globalPath, encoding: .utf8)) ?? ""
            let projectContent: String
            if let projectPath {
                projectContent = (try? String(contentsOf: projectPath, encoding: .utf8)) ?? ""
            } else {
                projectContent = ""
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.claudeMDGlobalContent = globalContent
                self.claudeMDProjectContent = projectContent
                self.claudeMDHasUnsavedChanges = false
            }
        }
    }

    @MainActor
    func saveClaudeMD() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let tab = claudeMDEditorTab
        let globalContent = claudeMDGlobalContent
        let projectContent = claudeMDProjectContent
        let projectPath: URL?
        if let project = claudeMDEditorProject ?? selectedProject {
            projectPath = findProjectClaudeMD(for: project)
        } else {
            projectPath = nil
        }

        claudeMDHasUnsavedChanges = false

        Task.detached(priority: .userInitiated) {
            switch tab {
            case .global:
                let globalPath = homeDir.appendingPathComponent(".claude/CLAUDE.md")
                try? globalContent.write(to: globalPath, atomically: true, encoding: .utf8)
            case .project:
                if let projectPath {
                    try? projectContent.write(to: projectPath, atomically: true, encoding: .utf8)
                }
            }
        }
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

    // MARK: - External Source Management

    @MainActor
    func addSource(name: String, path: String) {
        let source = ConversationSource(name: name, path: path)
        externalSources.append(source)
        ConversationSource.saveAll(externalSources)
        loadProjects()
        // Index in background
        Task {
            await reindexSource(source)
        }
        configureFileWatchers()
    }

    @MainActor
    func removeSource(_ id: UUID) {
        externalSources.removeAll { $0.id == id }
        ConversationSource.saveAll(externalSources)
        loadProjects()
        configureFileWatchers()
    }

    @MainActor
    func toggleSource(_ id: UUID) {
        guard let idx = externalSources.firstIndex(where: { $0.id == id }) else { return }
        externalSources[idx].isEnabled.toggle()
        ConversationSource.saveAll(externalSources)
        loadProjects()
        configureFileWatchers()
    }

    @MainActor
    func renameSource(_ id: UUID, to name: String) {
        guard let idx = externalSources.firstIndex(where: { $0.id == id }) else { return }
        externalSources[idx].name = name
        ConversationSource.saveAll(externalSources)
    }

    @MainActor
    func reindexSource(_ source: ConversationSource) async {
        guard source.isAccessible, let store else { return }
        isIndexing = true
        indexingStatus = "Indexing \(source.name)..."
        do {
            try await store.indexDirectory(URL(fileURLWithPath: source.path))
            if let idx = externalSources.firstIndex(where: { $0.id == source.id }) {
                externalSources[idx].lastIndexed = Date()
                ConversationSource.saveAll(externalSources)
            }
        } catch {
            indexingStatus = "Error indexing \(source.name)"
        }
        isIndexing = false
        indexingStatus = ""
        loadProjects()
    }

    @MainActor
    func reindexAllSources() async {
        for source in externalSources where source.isEnabled && source.isAccessible {
            await reindexSource(source)
        }
    }

    // MARK: - Live index updates

    /// Directories that should keep the local cache current. Kept separate for
    /// deterministic tests and to ensure duplicate source roots have one watcher.
    nonisolated static func watcherPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        externalSources: [ConversationSource]
    ) -> [URL] {
        let localProjects = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        // Codex writes rollouts continuously, so it gets a watcher too. Cursor
        // writes into one multi-gigabyte database that every keystroke touches;
        // it refreshes on launch and on demand instead.
        let codexSessions = AgentKind.isEnabled(.codex)
            ? [homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)]
            : []
        let paths = [localProjects] + codexSessions + externalSources
            .filter { $0.isEnabled && $0.isAccessible }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }

        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    @MainActor
    private func configureFileWatchers() {
        fileWatchers.forEach { $0.stop() }
        fileWatchers = Self.watcherPaths(externalSources: externalSources).map { path in
            FileWatcher(path: path) { [weak self] in
                Task { @MainActor in
                    self?.scheduleWatchedIndexRefresh()
                }
            }
        }
        fileWatchers.forEach { $0.start() }
    }

    @MainActor
    private func scheduleWatchedIndexRefresh() {
        watcherRefreshTask?.cancel()
        let generation = UUID()
        watcherRefreshGeneration = generation

        watcherRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  self.watcherRefreshGeneration == generation else { return }

            // Do not compete with an explicit or startup index. A later
            // filesystem event will schedule the same mod-date-aware pass.
            guard !self.isIndexing else { return }

            self.isIndexing = true
            self.indexingStatus = "Updating index…"
            defer {
                self.isIndexing = false
                self.indexingStatus = ""
                if self.watcherRefreshGeneration == generation {
                    self.watcherRefreshTask = nil
                }
            }

            guard let store = self.store else { return }
            do {
                try await store.performFullIndex()
                for source in self.externalSources where source.isEnabled && source.isAccessible {
                    try await store.indexDirectory(URL(fileURLWithPath: source.path))
                    if let index = self.externalSources.firstIndex(where: { $0.id == source.id }) {
                        self.externalSources[index].lastIndexed = Date()
                    }
                }
                ConversationSource.saveAll(self.externalSources)
                self.loadProjects()
            } catch {
                self.indexingStatus = "Index update failed"
            }
        }
    }

    // MARK: - Private Helpers

    private var presentationWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
    }

    private func projectDisplayName(from folderName: String) -> String {
        return ConversationStore.deriveProjectName(from: folderName)
    }

    /// Read first user message — only reads first 64KB of file. Background-safe.
    private nonisolated static func readFirstUserMessageBackground(from file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { handle.closeFile() }

        guard let chunk = try? handle.read(upToCount: 65536) else { return nil }
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

    /// Count newlines efficiently using raw byte scanning. Never converts entire file to String.
    private nonisolated static func countLinesEfficient(in file: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { handle.closeFile() }

        var count = 0
        let newlineByte = UInt8(ascii: "\n")
        let bufferSize = 65536

        while true {
            guard let data = try? handle.read(upToCount: bufferSize), !data.isEmpty else { break }
            for byte in data where byte == newlineByte {
                count += 1
            }
        }
        return count
    }

    // MARK: - Static Parsing Helpers (thread-safe, used from background tasks)

    private nonisolated static func parseMessageTypeStatic(from json: [String: Any]) -> ConversationMessage.MessageType {
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

    private nonisolated static func parseTimestampStatic(from json: [String: Any]) -> Date? {
        if let ts = json["timestamp"] as? String {
            // Create per-call — ISO8601DateFormatter (NSFormatter subclass) is not thread-safe.
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fmtFrac.date(from: ts) { return date }
            let fmtPlain = ISO8601DateFormatter()
            fmtPlain.formatOptions = [.withInternetDateTime]
            return fmtPlain.date(from: ts)
        }
        if let ts = json["timestamp"] as? Double {
            return Date(timeIntervalSince1970: ts / 1000)
        }
        return nil
    }

    private nonisolated static func parseContentBlocksStatic(from json: [String: Any]) -> [ContentBlock] {
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
        guard let handle = try? FileHandle(forReadingFrom: session.filePath) else { return }
        defer { handle.closeFile() }

        let queryLower = query.lowercased()
        let bufferSize = 256 * 1024
        var leftover = ""

        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            guard let chunkString = String(data: chunk, encoding: .utf8) else { continue }
            leftover += chunkString
            var lines = leftover.components(separatedBy: "\n")
            leftover = lines.removeLast()

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let jsonData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

                let type = Self.parseMessageTypeStatic(from: json)
                let timestamp = Self.parseTimestampStatic(from: json) ?? Date()
                let fullText = Self.extractFullTextStatic(from: json)

                guard fullText.lowercased().contains(queryLower) else { continue }

                let snippet = Self.createSnippetStatic(from: fullText, query: query, contextLines: Int(contextLines))
                let uuid = (json["uuid"] as? String) ?? UUID().uuidString

                results.append(SearchResult(
                    id: resultId,
                    sessionId: session.id,
                    projectPath: project.displayName,
                    messageUuid: uuid,
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

        // Handle leftover
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let jsonData = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let type = Self.parseMessageTypeStatic(from: json)
            let timestamp = Self.parseTimestampStatic(from: json) ?? Date()
            let fullText = Self.extractFullTextStatic(from: json)

            if fullText.lowercased().contains(queryLower) {
                let snippet = Self.createSnippetStatic(from: fullText, query: query, contextLines: Int(contextLines))
                let uuid = (json["uuid"] as? String) ?? UUID().uuidString
                results.append(SearchResult(
                    id: resultId,
                    sessionId: session.id,
                    projectPath: project.displayName,
                    messageUuid: uuid,
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
    }

    private nonisolated static func extractFullTextStatic(from json: [String: Any]) -> String {
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

    private nonisolated static func createSnippetStatic(from text: String, query: String, contextLines: Int) -> String {
        let lines = text.components(separatedBy: .newlines)
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
